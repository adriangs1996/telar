//! The soft descriptor limit children start with. A process that raises its
//! own soft limit records the one it inherited first, and every child
//! spawned on a pty gets that one back between fork and exec, so programs
//! that still use select() never see descriptors past FD_SETSIZE.

const std = @import("std");
const Command = @import("Command.zig");
const Session = @import("Session.zig");

/// Whether `inherited` holds the limit the process started with. Set once,
/// before any raise, and read by children after fork.
var recorded: std.atomic.Value(bool) = .init(false);
var inherited: std.posix.rlimit = undefined;

/// Raises the process's soft descriptor limit to `wanted`, within its hard
/// limit, after recording the limit it inherited. A limit that cannot be
/// raised is kept.
///
/// ```zig
/// descriptor_limit.raise(1536);
/// ```
pub fn raise(wanted: std.posix.rlim_t) void {
    var limits = std.posix.getrlimit(.NOFILE) catch return;
    if (!recorded.load(.acquire)) {
        inherited = limits;
        recorded.store(true, .release);
    }

    if (limits.cur >= wanted) {
        return;
    }

    limits.cur = @min(wanted, limits.max);
    std.posix.setrlimit(.NOFILE, limits) catch {};
}

/// Gives a freshly forked child the soft limit the process inherited. Only
/// a syscall, so it is safe between fork and exec.
///
/// ```zig
/// descriptor_limit.restoreInChild();
/// ```
pub fn restoreInChild() void {
    if (!recorded.load(.acquire)) {
        return;
    }

    std.posix.setrlimit(.NOFILE, inherited) catch {};
}

test "a raised limit is restored to the inherited one" {
    const original = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, original) catch {};

    var lowered = original;
    lowered.cur = @min(original.cur, 256);
    try std.posix.setrlimit(.NOFILE, lowered);
    recorded.store(false, .release);
    defer recorded.store(false, .release);

    raise(lowered.cur + 64);
    try std.testing.expectEqual(@min(lowered.cur + 64, original.max), (try std.posix.getrlimit(.NOFILE)).cur);

    restoreInChild();
    try std.testing.expectEqual(lowered.cur, (try std.posix.getrlimit(.NOFILE)).cur);
}

test "a child spawned on a pty starts with the inherited limit" {
    const io = std.testing.io;
    const original = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, original) catch {};

    var lowered = original;
    lowered.cur = @min(original.cur, 256);
    try std.posix.setrlimit(.NOFILE, lowered);
    recorded.store(false, .release);
    defer recorded.store(false, .release);

    raise(lowered.cur + 64);

    const args = [_][*:0]const u8{ "/bin/sh", "-c", "ulimit -n" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{
        .cols = 20,
        .rows = 5,
    });
    defer session.deinit();

    var expected_buffer: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{d}\r\n", .{lowered.cur});
    var output: [64]u8 = undefined;
    var len: usize = 0;
    while (!std.mem.endsWith(u8, output[0..len], "\r\n")) {
        const read_len = try session.read(io, output[len..]);
        if (read_len == 0) {
            break;
        }

        len += read_len;
    }

    try std.testing.expectEqualStrings(expected, output[0..len]);
}

