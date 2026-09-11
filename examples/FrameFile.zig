const std = @import("std");
const CreateOptions = @import("CreateOptions.zig");
/// One regular file the source rewrites in place, mapped for its lifetime.
const FrameFile = @This();

path: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
map: []align(std.heap.page_size_min) u8 = &.{},

/// Maps one reusable frame slot. Example: `try file.create(dir, .{ .slot = 0, .byte_len = 4096 });`.
pub fn create(file: *FrameFile, directory: []const u8, options: CreateOptions) !void {
    const pid: u32 = @bitCast(std.c.getpid());
    const printed = try std.fmt.bufPrintZ(&file.path, "{s}/telar-frame-source-{x}-{d}.rgba", .{ directory, pid, options.slot });
    file.path_len = printed.len;
    _ = std.c.unlink(printed);
    const fd = std.c.open(printed, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) {
        return error.FrameFileUnavailable;
    }
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(options.byte_len)) != 0) {
        return error.FrameFileUnavailable;
    }
    file.map = try std.posix.mmap(
        null,
        options.byte_len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
}

pub fn name(file: *const FrameFile) [:0]const u8 {
    return file.path[0..file.path_len :0];
}

/// Releases the mapping and file once. Example: `defer file.destroy();`.
pub fn destroy(file: *FrameFile) void {
    if (file.map.len != 0) {
        std.posix.munmap(file.map);
    }
    if (file.path_len != 0) {
        _ = std.c.unlink(file.name());
    }
}
