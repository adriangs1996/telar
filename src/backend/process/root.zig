//! Bounded foreground-process identification for agent panes.
//!
//! `tcgetpgrp` is sampled by the observation worker. Native process metadata
//! is inspected only when that process group changes or while a new group is
//! inside its bounded acquisition window.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");

const schema = core.schema;

const Native = if (builtin.os.tag == .macos) struct {
    const c = @cImport({
        @cInclude("libproc.h");
        @cInclude("sys/sysctl.h");
    });
} else struct {};

pub const max_acquisition_attempts: u8 = 6;
pub const max_group_processes = 64;
pub const max_process_args_bytes = 16 * 1024;

pub const Cache = struct {
    process_group_id: ?u32 = null,
    provider: schema.AgentProvider = .unknown,
    attempts: u8 = 0,
    foreground_name: [schema.max_foreground_name_bytes]u8 = @splat(0),
    foreground_name_len: u8 = 0,

    pub fn init(executable: []const u8) Cache {
        var cache: Cache = .{};
        cache.setName(applicationName(.unknown, executable));
        return cache;
    }

    pub fn name(cache: *const Cache) []const u8 {
        return cache.foreground_name[0..cache.foreground_name_len];
    }

    fn setName(cache: *Cache, value: []const u8) void {
        const source = if (value.len == 0) "process" else value;
        const len = @min(source.len, cache.foreground_name.len);
        @memcpy(cache.foreground_name[0..len], source[0..len]);
        cache.foreground_name_len = @intCast(len);
    }
};

const Identification = struct {
    provider: schema.AgentProvider = .unknown,
    name: [schema.max_foreground_name_bytes]u8 = @splat(0),
    name_len: u8 = 0,

    fn init(provider: schema.AgentProvider, command: []const u8) Identification {
        var result: Identification = .{ .provider = provider };
        const value = applicationName(provider, command);
        @memcpy(result.name[0..value.len], value);
        result.name_len = @intCast(value.len);
        return result;
    }

    fn slice(result: *const Identification) []const u8 {
        return result.name[0..result.name_len];
    }
};

pub const Probe = struct {
    cache: Cache,
    changed: bool = false,
    inspected: bool = false,
};

const ProbeInput = struct {
    process_group_id: ?std.c.pid_t,
    shell_pid: std.c.pid_t,
    previous: Cache,
};

/// Resolve a process group without allocating. A known group is cached until
/// `tcgetpgrp` reports a different one. Unknown groups receive a small bounded
/// retry window because process metadata can lag just behind terminal control.
///
/// ```zig
/// const result = probe(process_group_id, shell_pid, previous);
/// ```
pub fn probe(process_group_id: ?std.c.pid_t, shell_pid: std.c.pid_t, previous: Cache) Probe {
    return probeWith(.{ .process_group_id = process_group_id, .shell_pid = shell_pid, .previous = previous }, identifyProcessGroup);
}

fn probeWith(input: ProbeInput, comptime identify: fn (u32) Identification) Probe {
    const process_group_id = input.process_group_id;
    const shell_pid = input.shell_pid;
    const previous = input.previous;

    const native_pgid = process_group_id orelse return .{ .cache = previous };
    const pgid = std.math.cast(u32, native_pgid) orelse return .{ .cache = previous };
    const shell = std.math.cast(u32, shell_pid) orelse 0;

    if (pgid == shell) {
        if (previous.process_group_id == pgid and previous.foreground_name_len != 0)
            return .{ .cache = previous };
        const identification = identify(pgid);
        var next: Cache = .{ .process_group_id = pgid };
        next.setName(identification.slice());
        return .{ .cache = next, .changed = !sameCache(previous, next) };
    }
    if (previous.process_group_id == pgid and
        (previous.provider != .unknown or previous.attempts >= max_acquisition_attempts))
        return .{ .cache = previous };

    const identification = identify(pgid);
    var next: Cache = .{
        .process_group_id = pgid,
        .provider = identification.provider,
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
        .changed = !sameCache(previous, next),
        .inspected = true,
    };
}

pub fn shellForeground(cache: Cache, shell_pid: std.c.pid_t) bool {
    const shell = std.math.cast(u32, shell_pid) orelse return false;
    return cache.process_group_id == shell;
}

fn sameCache(left: Cache, right: Cache) bool {
    return left.process_group_id == right.process_group_id and
        left.provider == right.provider and
        left.attempts == right.attempts and
        std.mem.eql(u8, left.name(), right.name());
}

fn identifyProcessGroup(process_group_id: u32) Identification {
    return switch (builtin.os.tag) {
        .macos => identifyMacosProcessGroup(process_group_id),
        .linux => identifyLinuxProcessGroup(process_group_id),
        else => .{},
    };
}

fn identifyMacosProcessGroup(process_group_id: u32) Identification {
    if (comptime builtin.os.tag != .macos) return .{};
    if (process_group_id > std.math.maxInt(c_int)) return .{};

    var pids: [max_group_processes]std.c.pid_t = @splat(0);
    const byte_count = Native.c.proc_listpids(
        Native.c.PROC_PGRP_ONLY,
        process_group_id,
        &pids,
        @intCast(@sizeOf(@TypeOf(pids))),
    );
    if (byte_count <= 0) return identifyMacosProcess(process_group_id);

    const count = @min(
        pids.len,
        @as(usize, @intCast(byte_count)) / @sizeOf(std.c.pid_t),
    );
    // The group leader is the most useful candidate and avoids depending on
    // libproc's enumeration order.
    const leader = identifyMacosProcess(process_group_id);
    if (leader.provider != .unknown) return leader;
    var fallback = leader;
    for (pids[0..count]) |pid| {
        const candidate = std.math.cast(u32, pid) orelse continue;
        if (candidate == process_group_id) continue;
        const identified = identifyMacosProcess(candidate);
        if (identified.provider != .unknown) return identified;
        if (fallback.name_len == 0 and identified.name_len != 0) fallback = identified;
    }
    return fallback;
}

fn identifyMacosProcess(pid: u32) Identification {
    if (comptime builtin.os.tag != .macos) return .{};
    if (pid > std.math.maxInt(c_int)) return .{};

    var info: Native.c.proc_bsdinfo = std.mem.zeroes(Native.c.proc_bsdinfo);
    const expected: c_int = @intCast(@sizeOf(Native.c.proc_bsdinfo));
    if (Native.c.proc_pidinfo(
        @intCast(pid),
        Native.c.PROC_PIDTBSDINFO,
        0,
        &info,
        expected,
    ) != expected) return .{};

    const comm_bytes = std.mem.sliceAsBytes(info.pbi_comm[0..]);
    const comm_end = std.mem.indexOfScalar(u8, comm_bytes, 0) orelse comm_bytes.len;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const argv = readMacosArgv(pid, &args_buffer) orelse &.{};
    const command = comm_bytes[0..comm_end];
    return .init(identifyCommand(command, argv), command);
}

fn readMacosArgv(pid: u32, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    if (pid > std.math.maxInt(c_int)) return null;
    var mib = [_]c_int{ Native.c.CTL_KERN, Native.c.KERN_PROCARGS2, @intCast(pid) };
    var size = buffer.len;
    if (Native.c.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) != 0 or
        size < @sizeOf(c_int) or size > buffer.len) return null;

    const argc = std.mem.readInt(c_int, buffer[0..@sizeOf(c_int)], .native);
    if (argc < 1) return null;
    const rest = buffer[@sizeOf(c_int)..size];
    const executable_end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    var offset = executable_end;
    while (offset < rest.len and rest[offset] == 0) : (offset += 1) {}
    if (offset == rest.len) return null;
    return rest[offset..];
}

fn identifyLinuxProcessGroup(process_group_id: u32) Identification {
    if (comptime builtin.os.tag != .linux) return .{};
    var pending: [max_group_processes]u32 = @splat(0);
    var count: usize = 1;
    var index: usize = 0;
    pending[0] = process_group_id;

    var fallback: Identification = .{};
    while (index < count) : (index += 1) {
        const pid = pending[index];
        if (linuxProcessGroup(pid) != process_group_id) continue;
        const identified = identifyLinuxProcess(pid);
        if (identified.provider != .unknown) return identified;
        if (fallback.name_len == 0 and identified.name_len != 0) fallback = identified;
        appendLinuxChildren(pid, &pending, &count);
    }
    return fallback;
}

fn identifyLinuxProcess(pid: u32) Identification {
    if (comptime builtin.os.tag != .linux) return .{};
    var path_buffer: [64]u8 = undefined;
    var comm_buffer: [256]u8 = undefined;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid}) catch return .{};
    const comm = readSmallFile(comm_path, &comm_buffer) orelse return .{};
    const args_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch return .{};
    const argv = readSmallFile(args_path, &args_buffer) orelse &.{};
    const command = std.mem.trim(u8, comm, " \r\n\t");
    return .init(identifyCommand(command, argv), command);
}

fn linuxProcessGroup(pid: u32) ?u32 {
    if (comptime builtin.os.tag != .linux) return null;
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
    if (comptime builtin.os.tag != .linux) return;
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
        if (count.* == pending.len) return;
        const child = std.fmt.parseInt(u32, token, 10) catch continue;
        var duplicate = false;
        for (pending[0..count.*]) |known| {
            if (known == child) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        pending[count.*] = child;
        count.* += 1;
    }
}

fn readSmallFile(path: []const u8, buffer: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const len = file.read(buffer) catch return null;
    return buffer[0..len];
}

fn identifyCommand(comm: []const u8, argv: []const u8) schema.AgentProvider {
    if (providerFromToken(comm)) |provider| return provider;

    var args = std.mem.tokenizeScalar(u8, argv, 0);
    const argv0 = args.next() orelse return .unknown;
    if (providerFromToken(argv0)) |provider| return provider;
    if (!genericRuntime(argv0)) return .unknown;

    while (args.next()) |arg| {
        if (arg.len == 0 or arg[0] == '-') continue;
        if (providerFromExecutablePath(arg)) |provider| return provider;
        return .unknown;
    }
    return .unknown;
}

fn applicationName(provider: schema.AgentProvider, command: []const u8) []const u8 {
    return switch (provider) {
        .claude => "Claude Code",
        .codex => "Codex",
        .unknown => boundedCommandName(command),
    };
}

fn boundedCommandName(command: []const u8) []const u8 {
    const basename = pathBasename(command);
    const len = @min(basename.len, schema.max_foreground_name_bytes);
    const candidate = basename[0..len];
    if (candidate.len == 0 or !std.unicode.utf8ValidateSlice(candidate)) return "";
    for (candidate) |byte| if (byte < 0x20 or byte == 0x7f) return "";
    return candidate;
}

fn providerFromToken(token: []const u8) ?schema.AgentProvider {
    const basename = pathBasename(token);
    if (equalExecutableName(basename, "claude") or
        equalExecutableName(basename, "claude-code")) return .claude;
    if (equalExecutableName(basename, "codex")) return .codex;
    return null;
}

fn providerFromExecutablePath(path: []const u8) ?schema.AgentProvider {
    if (providerFromToken(path)) |provider| return provider;
    if (containsAsciiInsensitive(path, "/@anthropic-ai/claude-code/") or
        containsAsciiInsensitive(path, "\\@anthropic-ai\\claude-code\\")) return .claude;
    if (containsAsciiInsensitive(path, "/@openai/codex/") or
        containsAsciiInsensitive(path, "\\@openai\\codex\\")) return .codex;
    return null;
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
        if (byte == '/' or byte == '\\') start = index + 1;
    }
    return path[start..];
}

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset..][0..needle.len], needle)) return true;
    }
    return false;
}

fn endsWithAsciiInsensitive(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "identifies direct agent executables" {
    try std.testing.expectEqual(schema.AgentProvider.claude, identifyCommand("claude", "claude\x00"));
    try std.testing.expectEqual(schema.AgentProvider.claude, identifyCommand("node", "/usr/bin/node\x00/opt/claude-code/claude-code\x00"));
    try std.testing.expectEqual(schema.AgentProvider.codex, identifyCommand("codex", "codex\x00"));
    try std.testing.expectEqual(schema.AgentProvider.codex, identifyCommand("node", "node\x00/usr/lib/node_modules/@openai/codex/bin/codex.js\x00"));
}

test "does not infer an agent from arbitrary runtime arguments" {
    try std.testing.expectEqual(schema.AgentProvider.unknown, identifyCommand(
        "node",
        "node\x00script.js\x00tell claude to review this\x00",
    ));
}

test "process acquisition is bounded and cached" {
    const Fake = struct {
        fn claude(_: u32) Identification {
            return .init(.claude, "claude");
        }

        fn unknown(_: u32) Identification {
            return .init(.unknown, "node");
        }
    };
    const shell: std.c.pid_t = 10;
    const shell_probe = probeWith(.{
        .process_group_id = 10,
        .shell_pid = shell,
        .previous = .{ .process_group_id = 20, .provider = .claude },
    }, Fake.unknown);
    try std.testing.expect(shell_probe.changed);
    try std.testing.expect(shellForeground(shell_probe.cache, shell));
    try std.testing.expectEqual(schema.AgentProvider.unknown, shell_probe.cache.provider);

    const identified = probeWith(.{ .process_group_id = 20, .shell_pid = shell, .previous = .{} }, Fake.claude);
    try std.testing.expect(identified.changed);
    try std.testing.expect(identified.inspected);
    try std.testing.expectEqual(schema.AgentProvider.claude, identified.cache.provider);
    try std.testing.expectEqualStrings("Claude Code", identified.cache.name());
    const cached = probeWith(.{ .process_group_id = 20, .shell_pid = shell, .previous = identified.cache }, Fake.unknown);
    try std.testing.expect(!cached.changed);
    try std.testing.expect(!cached.inspected);

    var acquiring: Cache = .{};
    for (0..max_acquisition_attempts) |_| {
        const attempt = probeWith(.{ .process_group_id = 30, .shell_pid = shell, .previous = acquiring }, Fake.unknown);
        try std.testing.expect(attempt.inspected);
        acquiring = attempt.cache;
    }
    const stable = probeWith(.{ .process_group_id = 30, .shell_pid = shell, .previous = acquiring }, Fake.claude);
    try std.testing.expect(!stable.changed);
    try std.testing.expect(!stable.inspected);
}

test "foreground names are bounded application labels" {
    try std.testing.expectEqualStrings("Claude Code", applicationName(.claude, "claude"));
    try std.testing.expectEqualStrings("zsh", applicationName(.unknown, "/bin/zsh"));
    try std.testing.expectEqualStrings("", applicationName(.unknown, "bad\x1bname"));
}
