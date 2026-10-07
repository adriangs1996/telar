//! Native working-directory lookup for an observed process.

const darwin = @import("darwin.zig");
const ProcVnodePathInfo = @import("ProcVnodePathInfo.zig").ProcVnodePathInfo;
const builtin = @import("builtin");
const std = @import("std");

const mac = if (builtin.os.tag == .macos) darwin else void;

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

    // SAFETY: proc_pidinfo must return the complete struct size before its path field is inspected.
    var info: ProcVnodePathInfo = undefined;
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
    // readlinkat returns the buffer length on truncation, not an error.
    // Read into scratch space so an exact-fit caller buffer remains valid.
    var target_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const result = std.c.readlinkat(std.posix.AT.FDCWD, path.ptr, &target_buffer, target_buffer.len);
    if (result <= 0) {
        return null;
    }

    const len: usize = @intCast(result);
    if (len >= target_buffer.len or len > buffer.len) {
        return null;
    }

    @memcpy(buffer[0..len], target_buffer[0..len]);
    return buffer[0..len];
}
