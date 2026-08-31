//! Native working-directory lookup for an observed process.

const std = @import("std");
const builtin = @import("builtin");

const mac = if (builtin.os.tag == .macos) @cImport({
    @cInclude("libproc.h");
}) else struct {};

/// Reads the current working directory reported by the operating system.
/// The returned slice borrows `buffer`; failure or insufficient space returns
/// `null` without allocating.
///
/// ```zig
/// const path = read(pid, &buffer) orelse return;
/// ```
pub fn read(pid: std.c.pid_t, buffer: []u8) ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => readMacos(pid, buffer),
        .linux => readLinux(pid, buffer),
        else => null,
    };
}

fn readMacos(pid: std.c.pid_t, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }

    var info: mac.struct_proc_vnodepathinfo = undefined;
    const size: c_int = @intCast(@sizeOf(@TypeOf(info)));
    if (mac.proc_pidinfo(pid, mac.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) {
        return null;
    }

    const source = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (source.len == 0 or source.len > buffer.len) {
        return null;
    }

    @memcpy(buffer[0..source.len], source);
    return buffer[0..source.len];
}

fn readLinux(pid: std.c.pid_t, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) {
        return null;
    }

    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/cwd", .{pid}) catch return null;
    const result = std.c.readlinkat(std.posix.AT.FDCWD, path.ptr, buffer.ptr, buffer.len);
    if (result < 0) {
        return null;
    }

    return buffer[0..@intCast(result)];
}

test "reads the current process working directory" {
    var expected_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const expected_len = try std.process.currentPath(std.testing.io, &expected_buffer);
    var actual_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const actual = read(std.c.getpid(), &actual_buffer) orelse return error.WorkingDirectoryUnavailable;

    try std.testing.expectEqualStrings(expected_buffer[0..expected_len], actual);
}

test "rejects a buffer that cannot hold the working directory" {
    var buffer: [1]u8 = undefined;

    try std.testing.expectEqual(@as(?[]const u8, null), read(std.c.getpid(), &buffer));
}
