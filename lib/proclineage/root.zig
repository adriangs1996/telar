//! The chain of parent processes above one process, read from the kernel:
//! `proc_pidinfo` on macOS and `/proc/<pid>/stat` on Linux. Nothing is
//! retained between calls and nothing allocates.

const builtin = @import("builtin");
const std = @import("std");
const darwin = @import("darwin.zig");

/// The first process, which every chain ends at.
pub const init_process: u32 = 1;

/// Bytes read from `/proc/<pid>/stat`: enough for the fields up to the
/// parent id after a command name of at most 16 bytes.
const stat_prefix_bytes = 128;
/// `/proc/<pid>/stat` for the largest pid, with its terminator.
const stat_path_bytes = 32;

/// Fills `buffer` with the parents of `pid`, nearest first, and returns the
/// filled part. The chain stops after the first process, at a process the
/// kernel no longer knows, or when `buffer` is full.
///
/// ```zig
/// var storage: [32]u32 = undefined;
/// const chain = proclineage.ancestors(@intCast(std.c.getpid()), &storage);
/// ```
pub fn ancestors(pid: u32, buffer: []u32) []const u32 {
    var count: usize = 0;
    var current = pid;

    while (count < buffer.len) {
        const next = parent(current) orelse break;
        buffer[count] = next;
        count += 1;

        if (next == init_process or next == current) {
            break;
        }

        current = next;
    }

    return buffer[0..count];
}

/// The parent of `pid`, or null when the kernel does not know `pid` or it
/// has no parent.
///
/// ```zig
/// const ppid = proclineage.parent(pid) orelse return;
/// ```
pub fn parent(pid: u32) ?u32 {
    if (pid == 0 or pid > std.math.maxInt(c_int)) {
        return null;
    }

    return switch (builtin.os.tag) {
        .macos => macosParent(pid),
        .linux => linuxParent(pid),
        else => null,
    };
}

fn macosParent(pid: u32) ?u32 {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }

    var info: darwin.c.proc_bsdshortinfo = std.mem.zeroes(darwin.c.proc_bsdshortinfo);
    const expected: c_int = @intCast(@sizeOf(darwin.c.proc_bsdshortinfo));
    const written = darwin.c.proc_pidinfo(
        @intCast(pid),
        darwin.c.PROC_PIDT_SHORTBSDINFO,
        0,
        &info,
        expected,
    );
    if (written != expected) {
        return null;
    }

    if (info.pbsi_ppid == 0) {
        return null;
    }

    return info.pbsi_ppid;
}

fn linuxParent(pid: u32) ?u32 {
    var path_buffer: [stat_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
    const flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    };
    const file = std.posix.openatZ(std.posix.AT.FDCWD, path, flags, 0) catch return null;
    defer _ = std.posix.system.close(file);

    var stat_buffer: [stat_prefix_bytes]u8 = undefined;
    const len = std.posix.read(file, &stat_buffer) catch return null;
    return parseStatParent(stat_buffer[0..len]);
}

// `pid (comm) state ppid ...`: the command name may hold spaces and
// parentheses, so the fields start after the last `)`.
fn parseStatParent(stat: []const u8) ?u32 {
    const name_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[name_end + 1 ..], ' ');
    _ = fields.next() orelse return null;
    const ppid = std.fmt.parseUnsigned(u32, fields.next() orelse return null, 10) catch return null;
    if (ppid == 0) {
        return null;
    }

    return ppid;
}

test "the chain of the running process starts at its parent and ends at the first process" {
    var storage: [64]u32 = undefined;
    const pid: u32 = @intCast(std.c.getpid());
    const chain = ancestors(pid, &storage);

    try std.testing.expect(chain.len != 0);
    try std.testing.expectEqual(@as(u32, @intCast(std.c.getppid())), chain[0]);
    try std.testing.expectEqual(init_process, chain[chain.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u32, chain, pid) == null);
}

test "a full buffer cuts the chain and an unknown process has none" {
    var storage: [1]u32 = undefined;
    const pid: u32 = @intCast(std.c.getpid());

    try std.testing.expectEqual(@as(usize, 1), ancestors(pid, &storage).len);
    try std.testing.expect(parent(0) == null);
    try std.testing.expectEqual(@as(usize, 0), ancestors(std.math.maxInt(u32), &storage).len);
}

test "stat parsing reads the parent after a name with spaces and parentheses" {
    try std.testing.expectEqual(@as(?u32, 41), parseStatParent("42 (a (b) c) S 41 42 42 0"));
    try std.testing.expect(parseStatParent("42 (init) S 0 1") == null);
    try std.testing.expect(parseStatParent("garbage") == null);
}
