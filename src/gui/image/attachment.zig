//! Local attachment I/O and decoding run only on the bounded media worker.
const std = @import("std");
const Image = @import("../diagrams/Image.zig");
const native = @cImport({
    @cInclude("sys/stat.h");
});

extern fn telar_gui_decode_attachment(bytes: [*]const u8, len: usize, width: *u32, height: *u32) ?[*]u8;

/// Validates the opened file before allocating or decoding its bounded snapshot.
/// Example: `var image = try attachment.load(io, allocator, path);`
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Image {
    try @import("telar-core").AgentImages.validatePath(path);
    var storage: [1025]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&storage, "{s}", .{path});
    const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        return error.UnsafeImageFile;
    }

    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    var stat: native.struct_stat = undefined;
    if (native.fstat(fd, &stat) != 0 or stat.st_mode & native.S_IFMT != native.S_IFREG or stat.st_uid != std.c.geteuid() or stat.st_size <= 0 or stat.st_size > 16 * 1024 * 1024) {
        return error.UnsafeImageFile;
    }

    const bytes = try allocator.alloc(u8, @intCast(stat.st_size));
    defer allocator.free(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    try reader.interface.readSliceAll(bytes);
    return decode(allocator, bytes);
}

/// Produces a bounded premultiplied texture independent of the source lifetime.
/// Example: `var image = try attachment.decode(allocator, png_bytes);`
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (@import("builtin").os.tag == .macos) {
        var width: u32 = 0;
        var height: u32 = 0;
        const pixels = telar_gui_decode_attachment(bytes.ptr, bytes.len, &width, &height) orelse return error.InvalidImage;
        defer std.c.free(pixels);
        if (width == 0 or height == 0 or width > 2048 or height > 2048) {
            return error.InvalidImage;
        }

        return .{ .width = width, .height = height, .logical_width = @floatFromInt(width), .logical_height = @floatFromInt(height), .pixels = try allocator.dupe(u8, pixels[0 .. @as(usize, width) * height * 4]) };
    }

    var decoded = try @import("png.zig").decode(allocator, bytes, .{ .max_side = 2048, .max_pixels = Image.max_pixels });
    for (0..@as(usize, decoded.width) * decoded.height) |index| {
        const pixel = decoded.pixels[index * 4 ..][0..4];
        for (pixel[0..3]) |*channel| {
            channel.* = @intCast((@as(u16, channel.*) * pixel[3] + 127) / 255);
        }
    }

    return .{ .width = decoded.width, .height = decoded.height, .logical_width = @floatFromInt(decoded.width), .logical_height = @floatFromInt(decoded.height), .pixels = decoded.pixels };
}

test "attachment decoding preserves orientation and premultiplies transparent pixels" {
    const allocator = std.testing.allocator;
    const bytes = try @import("png.zig").encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba } }, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 0 });
    defer allocator.free(bytes);
    var image = try decode(allocator, bytes);
    defer image.deinit(allocator);
    try std.testing.expect(image.valid());
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0 }, image.pixels);
    if (decode(allocator, "corrupt image")) |value| {
        var unexpected = value;
        unexpected.deinit(allocator);
        return error.AcceptedCorruptImage;
    } else |_| {}
}

test "attachment worker rejects symlinks directories and missing files before decoding" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "image.png", .data = "invalid" });
    try temp.dir.symLink(io, "image.png", "link.png", .{});
    try temp.dir.createDir(io, "directory.png", .default_dir);
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temp.dir.realPath(io, &directory);
    for ([_][]const u8{ "link.png", "directory.png", "missing.png" }) |name| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ directory[0..len], name });
        try std.testing.expectError(error.UnsafeImageFile, load(io, std.testing.allocator, path));
    }
}
