//! Bounded foreground-process identification for agent panes.
//!
//! `tcgetpgrp` is sampled by the observation worker. Native process metadata
//! is inspected only when that process group changes or while a new group is
//! inside its bounded acquisition window.

const core = @import("telar-core");
const builtin = @import("builtin");
const Probe = @import("Probe.zig");
const Identification = @import("Identification.zig");
const std = @import("std");
const Cache = @import("Cache.zig");
const darwin = @import("darwin.zig");
const ProcBsdInfo = @import("ProcBsdInfo.zig").ProcBsdInfo;
const providers = @import("../agent/providers/providers.zig");
const SessionHost = @import("../agent/SessionHost.zig").SessionHost;

const Native = if (builtin.os.tag == .macos) darwin else void;

pub const max_acquisition_attempts: u8 = 6;
pub const max_group_processes = 64;
pub const max_process_args_bytes = 16 * 1024;

/// Resolve a process group without allocating. A known group is cached until
/// `tcgetpgrp` reports a different one. Unknown groups receive a small bounded
/// retry window because process metadata can lag just behind terminal control.
///
/// ```zig
/// const result = probe(.{ .process_group_id = pgid, .previous = previous, .manifests = manifests });
/// ```
pub fn probe(input: ProbeInput) Probe {
    return probeWith(input, identifyProcessGroup);
}

fn probeWith(input: ProbeInput, comptime identify: fn (*const core.Table, u32, core.AgentProvider) Identification) Probe {
    const process_group_id = input.process_group_id;
    const previous = input.previous;

    const native_pgid = process_group_id orelse return .{ .cache = previous };
    const pgid = std.math.cast(u32, native_pgid) orelse return .{ .cache = previous };

    if (!previous.recheck and previous.process_group_id == pgid and
        (previous.provider != .unknown or previous.attempts >= max_acquisition_attempts))
    {
        return .{ .cache = previous };
    }

    // A recheck keeps the agent already identified while it still runs in
    // the group, even when another one, such as a tool it started, runs
    // there too.
    const prefer = if (previous.process_group_id == pgid) previous.provider else .unknown;
    const identification = identify(input.manifests, pgid, prefer);
    var next: Cache = .{
        .process_group_id = pgid,
        .provider = identification.provider,
        .session_host = identification.session_host,
        .agent_pid = identification.pid,
        .attempts = if (identification.provider == .unknown)
            if (previous.process_group_id == pgid)
                previous.attempts +| 1
            else
                1
        else
            0,
    };
    next.setName(identification.slice());
    return .{
        .cache = next,
        .changed = !sameIdentity(previous, next),
        .inspected = true,
    };
}

/// A recognized pane-root agent keeps agent authority even when its process
/// group matches the root PID. Example: `if (shellForeground(cache, root_pid)) expireProgress();`.
pub fn shellForeground(cache: Cache, shell_pid: std.c.pid_t) bool {
    const shell = std.math.cast(u32, shell_pid) orelse return false;
    return cache.provider == .unknown and cache.process_group_id == shell;
}

fn sameIdentity(left: Cache, right: Cache) bool {
    return left.process_group_id == right.process_group_id and
        left.provider == right.provider and
        left.session_host == right.session_host and
        left.agent_pid == right.agent_pid and
        std.mem.eql(u8, left.name(), right.name());
}

fn identifyProcessGroup(table: *const core.Table, process_group_id: u32, prefer: core.AgentProvider) Identification {
    return switch (builtin.os.tag) {
        .macos => identifyMacosProcessGroup(table, process_group_id, prefer),
        .linux => identifyLinuxProcessGroup(table, process_group_id, prefer),
        else => .{},
    };
}

// Chooses the agent a process group runs among its members other than the
// leader: the agent identified before while it still runs there, else the
// first agent found, else the first named process.
const GroupChoice = struct {
    prefer: core.AgentProvider,
    chosen: ?Identification = null,
    fallback: Identification = .{},

    // Offers one member; true once the choice cannot change.
    fn offer(self: *GroupChoice, candidate: Identification) bool {
        if (candidate.provider == .unknown) {
            if (self.fallback.name_len == 0 and candidate.name_len != 0) {
                self.fallback = candidate;
            }

            return false;
        }

        if (self.prefer == .unknown or candidate.provider == self.prefer) {
            self.chosen = candidate;
            return true;
        }

        if (self.chosen == null) {
            self.chosen = candidate;
        }

        return false;
    }

    fn result(self: *const GroupChoice) Identification {
        return self.chosen orelse self.fallback;
    }
};

fn identifyMacosProcessGroup(table: *const core.Table, process_group_id: u32, prefer: core.AgentProvider) Identification {
    if (comptime builtin.os.tag != .macos) {
        return .{};
    }
    if (process_group_id > std.math.maxInt(c_int)) {
        return .{};
    }

    var pids: [max_group_processes]std.c.pid_t = @splat(0);
    const byte_count = Native.proc_listpids(
        Native.PROC_PGRP_ONLY,
        process_group_id,
        &pids,
        @intCast(@sizeOf(@TypeOf(pids))),
    );
    if (byte_count <= 0) {
        return identifyMacosProcess(table, process_group_id);
    }

    const count = @min(
        pids.len,
        @as(usize, @intCast(byte_count)) / @sizeOf(std.c.pid_t),
    );
    // The group leader is the most useful candidate and avoids depending on
    // libproc's enumeration order.
    const leader = identifyMacosProcess(table, process_group_id);
    if (leader.provider != .unknown) {
        return leader;
    }
    var choice: GroupChoice = .{
        .prefer = prefer,
        .fallback = leader,
    };
    for (pids[0..count]) |pid| {
        const candidate = std.math.cast(u32, pid) orelse continue;
        if (candidate == process_group_id) {
            continue;
        }

        if (choice.offer(identifyMacosProcess(table, candidate))) {
            break;
        }
    }

    return choice.result();
}

fn identifyMacosProcess(table: *const core.Table, pid: u32) Identification {
    if (comptime builtin.os.tag != .macos) {
        return .{};
    }
    if (pid > std.math.maxInt(c_int)) {
        return .{};
    }

    var info: ProcBsdInfo = std.mem.zeroes(ProcBsdInfo);
    const expected: c_int = @intCast(@sizeOf(ProcBsdInfo));
    if (Native.proc_pidinfo(
        @intCast(pid),
        Native.PROC_PIDTBSDINFO,
        0,
        &info,
        expected,
    ) != expected) {
        return .{};
    }

    const comm_bytes = std.mem.sliceAsBytes(info.pbi_comm[0..]);
    const comm_end = std.mem.indexOfScalar(u8, comm_bytes, 0) orelse comm_bytes.len;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const argv = readMacosArgv(pid, &args_buffer) orelse &.{};
    const command = comm_bytes[0..comm_end];
    var identified = identifyArguments(table, command, argv);
    identified.pid = pid;
    return identified;
}

fn readMacosArgv(pid: u32, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }
    if (pid > std.math.maxInt(c_int)) {
        return null;
    }
    var mib = [_]c_int{ Native.CTL_KERN, Native.KERN_PROCARGS2, @intCast(pid) };
    var size = buffer.len;
    if (Native.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) != 0 or
        size < @sizeOf(c_int) or size > buffer.len)
    {
        return null;
    }

    const argc = std.mem.readInt(c_int, buffer[0..@sizeOf(c_int)], .native);
    if (argc < 1) {
        return null;
    }
    const rest = buffer[@sizeOf(c_int)..size];
    const executable_end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    var offset = executable_end;
    while (offset < rest.len and rest[offset] == 0) : (offset += 1) {}
    if (offset == rest.len) {
        return null;
    }
    return rest[offset..];
}

fn identifyLinuxProcessGroup(table: *const core.Table, process_group_id: u32, prefer: core.AgentProvider) Identification {
    if (comptime builtin.os.tag != .linux) {
        return .{};
    }
    var pending: [max_group_processes]u32 = @splat(0);
    var count: usize = 1;
    var index: usize = 0;
    pending[0] = process_group_id;

    var choice: GroupChoice = .{
        .prefer = prefer,
    };

    while (index < count) : (index += 1) {
        const pid = pending[index];
        if (linuxProcessGroup(pid) != process_group_id) {
            continue;
        }

        const identified = identifyLinuxProcess(table, pid);
        // The group leader is the most useful candidate.
        if (index == 0 and identified.provider != .unknown) {
            return identified;
        }

        if (choice.offer(identified)) {
            break;
        }

        appendLinuxChildren(pid, &pending, &count);
    }

    return choice.result();
}

fn identifyLinuxProcess(table: *const core.Table, pid: u32) Identification {
    if (comptime builtin.os.tag != .linux) {
        return .{};
    }
    var path_buffer: [64]u8 = undefined;
    var comm_buffer: [256]u8 = undefined;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid}) catch return .{};
    const comm = readSmallFile(comm_path, &comm_buffer) orelse return .{};
    const args_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch return .{};
    const argv = readSmallFile(args_path, &args_buffer) orelse &.{};
    const command = std.mem.trim(u8, comm, " \r\n\t");
    var identified = identifyArguments(table, command, argv);
    identified.pid = pid;
    return identified;
}

fn linuxProcessGroup(pid: u32) ?u32 {
    if (comptime builtin.os.tag != .linux) {
        return null;
    }
    var path_buffer: [64]u8 = undefined;
    var stat_buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
    const stat = readSmallFile(path, &stat_buffer) orelse return null;
    const command_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[command_end + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    _ = fields.next() orelse return null; // parent pid
    return std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch null;
}

fn appendLinuxChildren(pid: u32, pending: *[max_group_processes]u32, count: *usize) void {
    if (comptime builtin.os.tag != .linux) {
        return;
    }
    var path_buffer: [96]u8 = undefined;
    var children_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "/proc/{d}/task/{d}/children",
        .{ pid, pid },
    ) catch return;
    const children = readSmallFile(path, &children_buffer) orelse return;
    var tokens = std.mem.tokenizeScalar(u8, children, ' ');
    while (tokens.next()) |token| {
        if (count.* == pending.len) {
            return;
        }
        const child = std.fmt.parseInt(u32, token, 10) catch continue;
        var duplicate = false;
        for (pending[0..count.*]) |known| {
            if (known == child) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            continue;
        }
        pending[count.*] = child;
        count.* += 1;
    }
}

fn readSmallFile(path: []const u8, buffer: []u8) ?[]const u8 {
    const file = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer _ = std.posix.system.close(file);

    const len = std.posix.read(file, buffer) catch return null;
    return buffer[0..len];
}

fn identifyArguments(table: *const core.Table, command: []const u8, argv: []const u8) Identification {
    var identification: Identification = .init(table, identifyCommand(table, command, argv), command);
    identification.session_host = sessionHost(identification.provider, argv);
    return identification;
}

// Where an agent that keeps its interactive session in the pane only when
// started with an argument runs it. A subcommand that runs no interactive
// session, and arguments not read, claim nothing.
fn sessionHost(provider: core.AgentProvider, argv: []const u8) SessionHost {
    const capabilities = providers.of(provider);
    const argument = capabilities.pane_session_argument orelse return .unknown;
    if (argv.len == 0) {
        return .unknown;
    }

    var host: SessionHost = .shared_server;
    var args = std.mem.tokenizeScalar(u8, argv, 0);
    while (args.next()) |arg| {
        for (capabilities.batch_arguments) |batch| {
            if (std.mem.eql(u8, arg, batch)) {
                return .unknown;
            }
        }

        if (std.mem.eql(u8, arg, argument)) {
            host = .pane;
        }
    }

    return host;
}

fn identifyCommand(table: *const core.Table, comm: []const u8, argv: []const u8) core.AgentProvider {
    if (providerFromToken(table, comm)) |provider| {
        return provider;
    }

    var args = std.mem.tokenizeScalar(u8, argv, 0);
    const argv0 = args.next() orelse return .unknown;
    if (providerFromToken(table, argv0)) |provider| {
        return provider;
    }
    // A launcher may `exec -a` the runtime under the name the user typed, as
    // Cursor Agent does, so the kernel's name of the image counts as well.
    if (!genericRuntime(argv0) and !genericRuntime(comm)) {
        return .unknown;
    }

    while (args.next()) |arg| {
        if (arg.len == 0 or arg[0] == '-') {
            continue;
        }
        if (providerFromExecutablePath(table, arg)) |provider| {
            return provider;
        }
        return .unknown;
    }
    return .unknown;
}

/// The foreground name a pane shows: the manifest display name for a known
/// agent, otherwise the executable basename.
pub fn applicationName(table: *const core.Table, provider: core.AgentProvider, command: []const u8) []const u8 {
    if (provider == .unknown) {
        return boundedCommandName(command);
    }

    return table.displayName(provider);
}

pub fn boundedCommandName(command: []const u8) []const u8 {
    const basename = pathBasename(command);
    const len = @min(basename.len, core.max_foreground_name_bytes);
    const candidate = basename[0..len];
    if (candidate.len == 0 or !std.unicode.utf8ValidateSlice(candidate)) {
        return "";
    }
    for (candidate) |byte| if (byte < 0x20 or byte == 0x7f) return "";
    return candidate;
}

fn providerFromToken(table: *const core.Table, token: []const u8) ?core.AgentProvider {
    return table.providerFromExecutable(pathBasename(token));
}

fn providerFromExecutablePath(table: *const core.Table, path: []const u8) ?core.AgentProvider {
    if (providerFromToken(table, path)) |provider| {
        return provider;
    }
    return table.providerFromPath(path);
}

fn genericRuntime(token: []const u8) bool {
    const basename = pathBasename(token);
    return equalExecutableName(basename, "node") or
        equalExecutableName(basename, "bun") or
        equalExecutableName(basename, "deno");
}

fn equalExecutableName(actual: []const u8, expected: []const u8) bool {
    var end = actual.len;
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".js" }) |suffix| {
        if (endsWithAsciiInsensitive(actual[0..end], suffix)) {
            end -= suffix.len;
            break;
        }
    }
    return std.ascii.eqlIgnoreCase(actual[0..end], expected);
}

fn pathBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') {
            start = index + 1;
        }
    }
    return path[start..];
}

fn endsWithAsciiInsensitive(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) {
        return false;
    }
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

const ProbeInput = struct {
    process_group_id: ?std.c.pid_t,
    previous: Cache,
    manifests: *const core.Table = &core.builtin_table,
};
