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
};

pub const Probe = struct {
    cache: Cache,
    changed: bool = false,
    inspected: bool = false,
};

/// Resolve a process group without allocating. A known group is cached until
/// `tcgetpgrp` reports a different one. Unknown groups receive a small bounded
/// retry window because process metadata can lag just behind terminal control.
pub fn probe(
    process_group_id: ?std.c.pid_t,
    shell_pid: std.c.pid_t,
    previous: Cache,
) Probe {
    return probeWith(process_group_id, shell_pid, previous, identifyProcessGroup);
}

fn probeWith(
    process_group_id: ?std.c.pid_t,
    shell_pid: std.c.pid_t,
    previous: Cache,
    comptime identify: fn (u32) schema.AgentProvider,
) Probe {
    const native_pgid = process_group_id orelse return .{ .cache = previous };
    const pgid = std.math.cast(u32, native_pgid) orelse return .{ .cache = previous };
    const shell = std.math.cast(u32, shell_pid) orelse 0;

    if (pgid == shell) {
        const next: Cache = .{ .process_group_id = pgid };
        return .{ .cache = next, .changed = !sameCache(previous, next) };
    }
    if (previous.process_group_id == pgid and
        (previous.provider != .unknown or previous.attempts >= max_acquisition_attempts))
        return .{ .cache = previous };

    const provider = identify(pgid);
    const next: Cache = .{
        .process_group_id = pgid,
        .provider = provider,
        .attempts = if (provider == .unknown)
            if (previous.process_group_id == pgid)
                previous.attempts +| 1
            else
                1
        else
            0,
    };
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
        left.attempts == right.attempts;
}

fn identifyProcessGroup(process_group_id: u32) schema.AgentProvider {
    return switch (builtin.os.tag) {
        .macos => identifyMacosProcessGroup(process_group_id),
        .linux => identifyLinuxProcessGroup(process_group_id),
        else => .unknown,
    };
}

fn identifyMacosProcessGroup(process_group_id: u32) schema.AgentProvider {
    if (comptime builtin.os.tag != .macos) return .unknown;
    if (process_group_id > std.math.maxInt(c_int)) return .unknown;

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
    if (leader != .unknown) return leader;
    for (pids[0..count]) |pid| {
        const candidate = std.math.cast(u32, pid) orelse continue;
        if (candidate == process_group_id) continue;
        const provider = identifyMacosProcess(candidate);
        if (provider != .unknown) return provider;
    }
    return .unknown;
}

fn identifyMacosProcess(pid: u32) schema.AgentProvider {
    if (comptime builtin.os.tag != .macos) return .unknown;
    if (pid > std.math.maxInt(c_int)) return .unknown;

    var info: Native.c.proc_bsdinfo = std.mem.zeroes(Native.c.proc_bsdinfo);
    const expected: c_int = @intCast(@sizeOf(Native.c.proc_bsdinfo));
    if (Native.c.proc_pidinfo(
        @intCast(pid),
        Native.c.PROC_PIDTBSDINFO,
        0,
        &info,
        expected,
    ) != expected) return .unknown;

    const comm_bytes = std.mem.sliceAsBytes(info.pbi_comm[0..]);
    const comm_end = std.mem.indexOfScalar(u8, comm_bytes, 0) orelse comm_bytes.len;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const argv = readMacosArgv(pid, &args_buffer) orelse &.{};
    return identifyCommand(comm_bytes[0..comm_end], argv);
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

fn identifyLinuxProcessGroup(process_group_id: u32) schema.AgentProvider {
    if (comptime builtin.os.tag != .linux) return .unknown;
    var pending: [max_group_processes]u32 = @splat(0);
    var count: usize = 1;
    var index: usize = 0;
    pending[0] = process_group_id;

    while (index < count) : (index += 1) {
        const pid = pending[index];
        if (linuxProcessGroup(pid) != process_group_id) continue;
        const provider = identifyLinuxProcess(pid);
        if (provider != .unknown) return provider;
        appendLinuxChildren(pid, &pending, &count);
    }
    return .unknown;
}

fn identifyLinuxProcess(pid: u32) schema.AgentProvider {
    if (comptime builtin.os.tag != .linux) return .unknown;
    var path_buffer: [64]u8 = undefined;
    var comm_buffer: [256]u8 = undefined;
    var args_buffer: [max_process_args_bytes]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid}) catch return .unknown;
    const comm = readSmallFile(comm_path, &comm_buffer) orelse return .unknown;
    const args_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch return .unknown;
    const argv = readSmallFile(args_path, &args_buffer) orelse &.{};
    return identifyCommand(std.mem.trim(u8, comm, " \r\n\t"), argv);
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
        fn claude(_: u32) schema.AgentProvider {
            return .claude;
        }

        fn unknown(_: u32) schema.AgentProvider {
            return .unknown;
        }
    };
    const shell: std.c.pid_t = 10;
    const shell_probe = probe(10, shell, .{ .process_group_id = 20, .provider = .claude });
    try std.testing.expect(shell_probe.changed);
    try std.testing.expect(shellForeground(shell_probe.cache, shell));
    try std.testing.expectEqual(schema.AgentProvider.unknown, shell_probe.cache.provider);

    const identified = probeWith(20, shell, .{}, Fake.claude);
    try std.testing.expect(identified.changed);
    try std.testing.expect(identified.inspected);
    try std.testing.expectEqual(schema.AgentProvider.claude, identified.cache.provider);
    const cached = probeWith(20, shell, identified.cache, Fake.unknown);
    try std.testing.expect(!cached.changed);
    try std.testing.expect(!cached.inspected);

    var acquiring: Cache = .{};
    for (0..max_acquisition_attempts) |_| {
        const attempt = probeWith(30, shell, acquiring, Fake.unknown);
        try std.testing.expect(attempt.inspected);
        acquiring = attempt.cache;
    }
    const stable = probeWith(30, shell, acquiring, Fake.claude);
    try std.testing.expect(!stable.changed);
    try std.testing.expect(!stable.inspected);
}
