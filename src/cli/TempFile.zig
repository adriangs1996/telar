/// An owner-only temporary next to `path`, renamed over it on commit.
const TempFile = @This();
const source_namespace = @import("integration_support.zig");
const std = @import("std");
io: source_namespace.Io,
file: source_namespace.File,
path: []const u8,
temp_buffer: [std.fs.max_path_bytes]u8 = undefined,
temp_len: usize = 0,

pub fn begin(io: source_namespace.Io, path: []const u8) !TempFile {
    var temp: TempFile = .{ .io = io, .file = undefined, .path = path };
    const temp_path = try std.fmt.bufPrint(&temp.temp_buffer, "{s}.telar-tmp", .{path});
    temp.temp_len = temp_path.len;
    temp.file = try source_namespace.Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true, .permissions = source_namespace.File.Permissions.fromMode(0o600) });
    return temp;
}

fn tempPath(temp: *const TempFile) []const u8 {
    return temp.temp_buffer[0..temp.temp_len];
}

pub fn commit(temp: *TempFile) !void {
    temp.file.close(temp.io);
    try source_namespace.Io.Dir.renameAbsolute(temp.tempPath(), temp.path, temp.io);
}

pub fn discard(temp: *TempFile) void {
    temp.file.close(temp.io);
    source_namespace.Io.Dir.deleteFileAbsolute(temp.io, temp.tempPath()) catch {};
}
