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

fn tempPath(self: *const TempFile) []const u8 {
    return self.temp_buffer[0..self.temp_len];
}

pub fn commit(self: *TempFile) !void {
    self.file.close(self.io);
    try std.Io.Dir.renameAbsolute(self.tempPath(), self.path, self.io);
}

pub fn discard(self: *TempFile) void {
    self.file.close(self.io);
    std.Io.Dir.deleteFileAbsolute(self.io, self.tempPath()) catch {};
}
