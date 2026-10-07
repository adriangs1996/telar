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
// SAFETY: begin formats the temporary path before recording temp_len; commit and discard use only that prefix.
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
        // SAFETY: createFile assigns file before returning temp; formatting or open failure returns without using the handle.
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
        // Cleanup must preserve the rename failure that prevented the commit.
        cwd.deleteFile(self.io, self.tempPath()) catch {};
        return err;
    };
}

pub fn discard(self: *TempFile) void {
    self.file.close(self.io);
    // Discard closes the file first; inability to remove its private temporary path cannot be returned from cleanup.
    std.Io.Dir.cwd().deleteFile(self.io, self.tempPath()) catch {};
}
