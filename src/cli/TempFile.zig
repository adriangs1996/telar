const privatefile = @import("privatefile");
const std = @import("std");
/// An owner-only temporary beside `path`, created exclusively under a random
/// name and renamed over it once its bytes are on disk. Paths may be
/// relative to the working directory.
const TempFile = @This();

/// Random bytes in the temporary's name; hex doubles them.
const nonce_bytes = 8;

io: std.Io,
file: std.Io.File,
path: []const u8,
temp_buffer: [std.fs.max_path_bytes]u8 = undefined,
temp_len: usize = 0,

/// Creates the temporary. `O_EXCL` never opens an existing entry, so a file
/// or symlink planted at the name is never written through.
///
/// ```zig
/// var temp = try TempFile.begin(io, path);
/// temp.file.writeStreamingAll(io, bytes) catch |err| {
///     temp.discard();
///     return err;
/// };
/// try temp.commit();
/// ```
pub fn begin(io: std.Io, path: []const u8) !TempFile {
    var temp: TempFile = .{
        .io = io,
        .file = undefined,
        .path = path,
    };
    var nonce: [nonce_bytes]u8 = undefined;
    io.random(&nonce);
    const temp_path = try std.fmt.bufPrint(&temp.temp_buffer, "{s}.telar-tmp-{s}", .{ path, &std.fmt.bytesToHex(nonce, .lower) });
    temp.temp_len = temp_path.len;
    temp.file = try std.Io.Dir.cwd().createFile(io, temp_path, .{
        .exclusive = true,
        .permissions = .fromMode(@intFromEnum(privatefile.Mode.file)),
    });
    return temp;
}

fn tempPath(self: *const TempFile) []const u8 {
    return self.temp_buffer[0..self.temp_len];
}

/// Flushes the bytes to disk and renames the temporary over `path`; on
/// failure the temporary is removed and `path` keeps its old contents.
pub fn commit(self: *TempFile) !void {
    self.file.sync(self.io) catch |err| {
        self.discard();
        return err;
    };

    self.file.close(self.io);
    const cwd = std.Io.Dir.cwd();
    cwd.rename(self.tempPath(), cwd, self.path, self.io) catch |err| {
        cwd.deleteFile(self.io, self.tempPath()) catch {};
        return err;
    };
}

pub fn discard(self: *TempFile) void {
    self.file.close(self.io);
    std.Io.Dir.cwd().deleteFile(self.io, self.tempPath()) catch {};
}

fn entryCount(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(std.testing.io)) |_| {
        count += 1;
    }

    return count;
}

test "a committed file replaces the old one whole, owner-only, with no temporary left" {
    var temp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer temp_dir.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp_dir.dir.realPath(std.testing.io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/settings.json", .{directory});
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "old",
    });

    var temp = try TempFile.begin(std.testing.io, path);
    try temp.file.writeStreamingAll(std.testing.io, "new");
    try temp.commit();

    var bytes_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", try temp_dir.dir.readFile(std.testing.io, "settings.json", &bytes_buffer));
    const stat = try temp_dir.dir.statFile(std.testing.io, "settings.json", .{});
    try std.testing.expectEqual(@intFromEnum(privatefile.Mode.file), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(temp_dir.dir));

    var discarded = try TempFile.begin(std.testing.io, path);
    discarded.discard();
    try std.testing.expectEqual(@as(usize, 1), try entryCount(temp_dir.dir));
}

test "a symlink planted at the old temporary name is never written through" {
    var temp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer temp_dir.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp_dir.dir.realPath(std.testing.io, &directory_buffer)];
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "victim",
        .data = "keep",
    });
    try temp_dir.dir.symLink(std.testing.io, "victim", "settings.json.telar-tmp", .{});

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/settings.json", .{directory});
    var temp = try TempFile.begin(std.testing.io, path);
    try temp.file.writeStreamingAll(std.testing.io, "new");
    try temp.commit();

    var bytes_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try temp_dir.dir.readFile(std.testing.io, "victim", &bytes_buffer));
    try std.testing.expectEqualStrings("new", try temp_dir.dir.readFile(std.testing.io, "settings.json", &bytes_buffer));
}
