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

fn probeWith(input: ProbeInput, comptime identify: fn (*const core.Table, u32) Identification) Probe {
    const process_group_id = input.process_group_id;
    const previous = input.previous;

    const native_pgid = process_group_id orelse return .{ .cache = previous };
    const pgid = std.math.cast(u32, native_pgid) orelse return .{ .cache = previous };

    if (previous.process_group_id == pgid and
        (previous.provider != .unknown or previous.attempts >= max_acquisition_attempts))
    {
        return .{ .cache = previous };
    }

    const identification = identify(input.manifests, pgid);
    var next: Cache = .{
        .process_group_id = pgid,
        .provider = identification.provider,
        .session_host = identification.session_host,
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
        std.mem.eql(u8, left.name(), right.name());
}

fn identifyProcessGroup(table: *const core.Table, process_group_id: u32) Identification {
    return switch (builtin.os.tag) {
        .macos => identifyMacosProcessGroup(table, process_group_id),
        .linux => identifyLinuxProcessGroup(table, process_group_id),
        else => .{},
    };
}

fn identifyMacosProcessGroup(table: *const core.Table, process_group_id: u32) Identification {
    if (comptime builtin.os.tag != .macos) {
        return .{};
    }
    if (process_group_id > std.math.maxInt(c_int)) {
        return .{};
    }

    var pids: [max_group_processes]std.c.pid_t = @splat(0);
    const byte_count = Native.c.proc_listpids(
        Native.c.PROC_PGRP_ONLY,
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
    var fallback = leader;
    for (pids[0..count]) |pid| {
        const candidate = std.math.cast(u32, pid) orelse continue;
        if (candidate == process_group_id) {
            continue;
        }
        const identified = identifyMacosProcess(table, candidate);
        if (identified.provider != .unknown) {
            return identified;
        }
        if (fallback.name_len == 0 and identified.name_len != 0) {
            fallback = identified;
        }
    }
    return fallback;
}

fn identifyMacosProcess(table: *const core.Table, pid: u32) Identification {
    if (comptime builtin.os.tag != .macos) {
        return .{};
    }
    if (pid > std.math.maxInt(c_int)) {
        return .{};
    }

    var info: Native.c.proc_bsdinfo = std.mem.zeroes(Native.c.proc_bsdinfo);
    const expected: c_int = @intCast(@sizeOf(Native.c.proc_bsdinfo));
    if (Native.c.proc_pidinfo(
        @intCast(pid),
        Native.c.PROC_PIDTBSDINFO,
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
    return identifyArguments(table, command, argv);
}

fn readMacosArgv(pid: u32, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }
    if (pid > std.math.maxInt(c_int)) {
        return null;
    }
    var mib = [_]c_int{ Native.c.CTL_KERN, Native.c.KERN_PROCARGS2, @intCast(pid) };
    var size = buffer.len;
    if (Native.c.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) != 0 or
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

fn identifyLinuxProcessGroup(table: *const core.Table, process_group_id: u32) Identification {
    if (comptime builtin.os.tag != .linux) {
        return .{};
    }
    var pending: [max_group_processes]u32 = @splat(0);
    var count: usize = 1;
    var index: usize = 0;
    pending[0] = process_group_id;

    var fallback: Identification = .{};
    while (index < count) : (index += 1) {
        const pid = pending[index];
        if (linuxProcessGroup(pid) != process_group_id) {
            continue;
        }
        const identified = identifyLinuxProcess(table, pid);
        if (identified.provider != .unknown) {
            return identified;
        }
        if (fallback.name_len == 0 and identified.name_len != 0) {
            fallback = identified;
        }
        appendLinuxChildren(pid, &pending, &count);
    }
    return fallback;
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
    return identifyArguments(table, command, argv);
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

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) {
        return false;
    }
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset..][0..needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn endsWithAsciiInsensitive(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) {
        return false;
    }
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "process file reads are bounded and missing files return null" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "sample", .data = "abc\x00def" });
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/sample", .{directory_buffer[0..directory_len]});
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("abc\x00", readSmallFile(path, &buffer).?);
    try temp.dir.deleteFile(io, "sample");
    try std.testing.expectEqual(@as(?[]const u8, null), readSmallFile(path, &buffer));
}

test "only an interactive Codex session started without --no-daemon may run in the shared server" {
    const table = &core.builtin_table;
    const Case = struct {
        argv: []const u8,
        host: SessionHost,
    };
    const cases = [_]Case{
        .{
            .argv = "codex\x00",
            .host = .shared_server,
        },
        .{
            .argv = "codex\x00resume\x00",
            .host = .shared_server,
        },
        .{
            .argv = "codex\x00fix the tests\x00",
            .host = .shared_server,
        },
        .{
            .argv = "node\x00/usr/lib/node_modules/@openai/codex/bin/codex.js\x00--yolo\x00",
            .host = .shared_server,
        },
        .{
            .argv = "codex\x00resume\x00--no-daemon\x00019a0000-0000-7000-8000-00000000000a\x00",
            .host = .pane,
        },
        .{
            .argv = "codex\x00--no-daemon\x00",
            .host = .pane,
        },
        .{
            .argv = "codex\x00exec\x00fix the tests\x00",
            .host = .unknown,
        },
        .{
            .argv = "codex\x00review\x00",
            .host = .unknown,
        },
        .{
            .argv = "codex\x00login\x00",
            .host = .unknown,
        },
        .{
            .argv = "codex\x00app-server\x00--listen\x00unix://\x00",
            .host = .unknown,
        },
        .{
            .argv = "codex\x00--version\x00",
            .host = .unknown,
        },
        .{
            .argv = "",
            .host = .unknown,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.host, identifyArguments(table, "codex", case.argv).session_host);
    }

    try std.testing.expectEqual(SessionHost.unknown, identifyArguments(table, "claude", "claude\x00").session_host);
}

test "identifies direct agent executables" {
    try std.testing.expectEqual(core.AgentProvider.claude, identifyCommand(&core.builtin_table, "claude", "claude\x00"));
    try std.testing.expectEqual(core.AgentProvider.claude, identifyCommand(&core.builtin_table, "node", "/usr/bin/node\x00/opt/claude-code/claude-code\x00"));
    try std.testing.expectEqual(core.AgentProvider.codex, identifyCommand(&core.builtin_table, "codex", "codex\x00"));
    try std.testing.expectEqual(core.AgentProvider.codex, identifyCommand(&core.builtin_table, "node", "node\x00/usr/lib/node_modules/@openai/codex/bin/codex.js\x00"));
}

test "identifies Cursor Agent under the name its launcher gave the runtime" {
    const entry = "/Users/me/.local/share/cursor-agent/versions/2026.09.26-dd393fe/index.js\x00";
    try std.testing.expectEqual(core.AgentProvider.cursor, identifyCommand(&core.builtin_table, "node", "/Users/me/.local/bin/agent\x00--use-system-ca\x00" ++ entry ++ "--model\x00auto\x00"));
    try std.testing.expectEqual(core.AgentProvider.cursor, identifyCommand(&core.builtin_table, "node", "/Users/me/.local/bin/cursor-agent\x00--use-system-ca\x00" ++ entry));
    try std.testing.expectEqual(core.AgentProvider.cursor, identifyCommand(&core.builtin_table, "node", "agent\x00" ++ entry));
    try std.testing.expectEqual(core.AgentProvider.unknown, identifyCommand(&core.builtin_table, "agent", "agent\x00" ++ entry));
}

test "identifies OpenCode's executable and its npm launcher" {
    try std.testing.expectEqual(core.AgentProvider.opencode, identifyCommand(&core.builtin_table, "opencode", "/opt/homebrew/Cellar/opencode/1.18.30_1/bin/opencode\x00-m\x00opencode/big-pickle\x00"));
    try std.testing.expectEqual(core.AgentProvider.opencode, identifyCommand(&core.builtin_table, "node", "node\x00/usr/local/lib/node_modules/opencode-ai/bin/opencode\x00--session\x00ses_f212d4cc3ffeR3t3CA08EwN5Ap\x00"));
}

test "does not infer an agent from arbitrary runtime arguments" {
    try std.testing.expectEqual(core.AgentProvider.unknown, identifyCommand(
        &core.builtin_table,
        "node",
        "node\x00script.js\x00tell claude to review this\x00",
    ));
}

test "process acquisition is bounded and cached" {
    const Fake = struct {
        fn claude(table: *const core.Table, _: u32) Identification {
            return .init(table, .claude, "claude");
        }

        fn unknown(table: *const core.Table, _: u32) Identification {
            return .init(table, .unknown, "node");
        }
    };
    const shell: std.c.pid_t = 10;
    const shell_probe = probeWith(.{
        .process_group_id = 10,
        .previous = .{ .process_group_id = 20, .provider = .claude },
    }, Fake.unknown);
    try std.testing.expect(shell_probe.changed);
    try std.testing.expect(shellForeground(shell_probe.cache, shell));
    try std.testing.expectEqual(core.AgentProvider.unknown, shell_probe.cache.provider);

    const identified = probeWith(.{ .process_group_id = 20, .previous = .{} }, Fake.claude);
    try std.testing.expect(identified.changed);
    try std.testing.expect(identified.inspected);
    try std.testing.expectEqual(core.AgentProvider.claude, identified.cache.provider);
    try std.testing.expectEqualStrings("Claude Code", identified.cache.name());
    const cached = probeWith(.{ .process_group_id = 20, .previous = identified.cache }, Fake.unknown);
    try std.testing.expect(!cached.changed);
    try std.testing.expect(!cached.inspected);

    var acquiring: Cache = .{};
    for (0..max_acquisition_attempts) |_| {
        const attempt = probeWith(.{ .process_group_id = 30, .previous = acquiring }, Fake.unknown);
        try std.testing.expect(attempt.inspected);
        acquiring = attempt.cache;
    }
    const stable = probeWith(.{ .process_group_id = 30, .previous = acquiring }, Fake.claude);
    try std.testing.expect(!stable.changed);
    try std.testing.expect(!stable.inspected);
}

test "foreground names are bounded application labels" {
    try std.testing.expectEqualStrings("Claude Code", applicationName(&core.builtin_table, .claude, "claude"));
    try std.testing.expectEqualStrings("Pi", applicationName(&core.builtin_table, .pi, "node"));
    try std.testing.expectEqualStrings("zsh", applicationName(&core.builtin_table, .unknown, "/bin/zsh"));
    try std.testing.expectEqualStrings("", applicationName(&core.builtin_table, .unknown, "bad\x1bname"));
}

test "direct pane-root agents retain provider evidence instead of becoming shells" {
    const Fake = struct {
        fn identify(table: *const core.Table, pid: u32) Identification {
            const provider: core.AgentProvider = switch (pid) {
                10 => .claude,
                11 => .codex,
                else => .pi,
            };
            return .init(table, provider, "node");
        }

        fn unexpected(_: *const core.Table, _: u32) Identification {
            unreachable;
        }
    };

    for ([_]std.c.pid_t{ 10, 11, 12 }) |root_pid| {
        const detected = probeWith(.{ .process_group_id = root_pid, .previous = .init("node") }, Fake.identify);
        try std.testing.expect(detected.cache.provider != .unknown);
        try std.testing.expect(detected.changed);
        try std.testing.expect(detected.inspected);
        try std.testing.expect(!shellForeground(detected.cache, root_pid));
        const cached = probeWith(.{ .process_group_id = root_pid, .previous = detected.cache }, Fake.unexpected);
        try std.testing.expect(!cached.inspected);
        try std.testing.expect(!cached.changed);
        try std.testing.expectEqualDeep(detected.cache, cached.cache);
    }
}

test "pane-root acquisition can recognize an agent after exec in the same process group" {
    const Fake = struct {
        fn starting(table: *const core.Table, _: u32) Identification {
            return .init(table, .unknown, "node");
        }

        fn ready(table: *const core.Table, _: u32) Identification {
            return .init(table, .codex, "codex");
        }
    };

    const root_pid: std.c.pid_t = 10;
    const starting = probeWith(.{ .process_group_id = root_pid, .previous = .init("node") }, Fake.starting);
    try std.testing.expectEqual(core.AgentProvider.unknown, starting.cache.provider);
    const retry = probeWith(.{ .process_group_id = root_pid, .previous = starting.cache }, Fake.starting);
    try std.testing.expect(retry.inspected);
    try std.testing.expect(!retry.changed);
    try std.testing.expectEqual(starting.cache.attempts + 1, retry.cache.attempts);
    const ready = probeWith(.{ .process_group_id = root_pid, .previous = retry.cache }, Fake.ready);
    try std.testing.expectEqual(core.AgentProvider.codex, ready.cache.provider);
    try std.testing.expect(ready.inspected);
    try std.testing.expect(!shellForeground(ready.cache, root_pid));
}

const ProbeInput = struct {
    process_group_id: ?std.c.pid_t,
    previous: Cache,
    manifests: *const core.Table = &core.builtin_table,
};
