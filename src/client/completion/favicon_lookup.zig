//! Finds and reads a workspace's favicon file off the interactive path:
//! `favicon.png`, `favicon.ico`, then `.telar/icon.png` under the workspace root, regular
//! files only, at most `max_file_bytes`. Decoding belongs to the adapter.
const std = @import("std");
const max_cwd_bytes = @import("telar-core").max_cwd_bytes;

pub const max_file_bytes: usize = 1024 * 1024;
pub const candidates = [_][]const u8{ "favicon.png", "favicon.ico", ".telar/icon.png" };

/// Reads the first candidate that exists into `buffer`, which must hold
/// `max_file_bytes`. A larger or irregular file is skipped like a missing one.
/// Example: `const bytes = try favicon_lookup.read(io, cwd, buffer);`
pub fn read(io: std.Io, cwd: []const u8, buffer: []u8) ![]const u8 {
    std.debug.assert(buffer.len >= max_file_bytes);
    if (cwd.len == 0 or cwd.len > max_cwd_bytes) {
        return error.FaviconNotFound;
    }

    var path: [max_cwd_bytes + 32]u8 = undefined;
    for (candidates) |name| {
        const joined = std.fmt.bufPrint(&path, "{s}/{s}", .{ cwd, name }) catch continue;
        if (readRegular(io, joined, buffer[0..max_file_bytes]) catch null) |bytes| {
            return bytes;
        }
    }

    return error.FaviconNotFound;
}

fn readRegular(io: std.Io, path: []const u8, buffer: []u8) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > buffer.len) {
        return null;
    }

    const len = try file.readPositionalAll(io, buffer[0..@intCast(stat.size)], 0);
    return buffer[0..len];
}

test "the lookup prefers favicon.png, falls back to .telar/icon.png and skips oversized files" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const buffer = try std.testing.allocator.alloc(u8, max_file_bytes);
    defer std.testing.allocator.free(buffer);
    try std.testing.expectError(error.FaviconNotFound, read(io, root, buffer));

    try temp.dir.createDirPath(io, ".telar");
    try temp.dir.writeFile(io, .{ .sub_path = ".telar/icon.png", .data = "fallback" });
    try std.testing.expectEqualStrings("fallback", try read(io, root, buffer));

    try temp.dir.writeFile(io, .{ .sub_path = "favicon.ico", .data = "icon" });
    try std.testing.expectEqualStrings("icon", try read(io, root, buffer));

    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = "primary" });
    try std.testing.expectEqualStrings("primary", try read(io, root, buffer));

    const huge = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = huge });
    try std.testing.expectEqualStrings("icon", try read(io, root, buffer));
    try temp.dir.deleteFile(io, "favicon.ico");
    try std.testing.expectEqualStrings("fallback", try read(io, root, buffer));

    try temp.dir.deleteFile(io, ".telar/icon.png");
    try temp.dir.createDirPath(io, ".telar/icon.png");
    try std.testing.expectError(error.FaviconNotFound, read(io, root, buffer));
    try std.testing.expectError(error.FaviconNotFound, read(io, "", buffer));
}

test "workspace favicons larger than 256 KiB are readable up to the file bound" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const buffer = try std.testing.allocator.alloc(u8, max_file_bytes);
    defer std.testing.allocator.free(buffer);
    const data = try std.testing.allocator.alloc(u8, max_file_bytes);
    defer std.testing.allocator.free(data);
    @memset(data, 0x5a);
    for ([_][]const u8{ "favicon.png", "favicon.ico" }) |name| {
        for ([_]usize{ 370070, 446080, max_file_bytes }) |size| {
            try temp.dir.writeFile(io, .{ .sub_path = name, .data = data[0..size] });
            try std.testing.expectEqualSlices(u8, data[0..size], try read(io, root, buffer));
        }

        try temp.dir.deleteFile(io, name);
    }
}
