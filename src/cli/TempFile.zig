const std = @import("std");
/// An owner-only temporary next to `path`, renamed over it on commit.
const TempFile = @This();

io: std.Io,
file: std.Io.File,
path: []const u8,
temp_buffer: [std.fs.max_path_bytes]u8 = undefined,
temp_len: usize = 0,

pub fn begin(io: std.Io, path: []const u8) !TempFile {
    var temp: TempFile = .{ .io = io, .file = undefined, .path = path };
    const temp_path = try std.fmt.bufPrint(&temp.temp_buffer, "{s}.telar-tmp", .{path});
    temp.temp_len = temp_path.len;
    temp.file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    return temp;
}

fn tempPath(temp: *const TempFile) []const u8 {
    return temp.temp_buffer[0..temp.temp_len];
}

pub fn commit(temp: *TempFile) !void {
    temp.file.close(temp.io);
    try std.Io.Dir.renameAbsolute(temp.tempPath(), temp.path, temp.io);
}

pub fn discard(temp: *TempFile) void {
    temp.file.close(temp.io);
    std.Io.Dir.deleteFileAbsolute(temp.io, temp.tempPath()) catch {};
}
