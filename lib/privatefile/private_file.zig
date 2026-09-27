const std = @import("std");

/// Permission bits a private file and its directory carry.
pub const Mode = enum(u32) {
    /// Read and write for the owner only.
    file = 0o600,
    /// The owner may list and create entries; nobody else may.
    directory = 0o700,
    /// Any bit a group or other user could use.
    shared = 0o077,
};

/// Reads an owner-only regular file whole, up to `limit` bytes. A missing
/// file is null. A symlink, a directory or a file anyone else may read or
/// write is refused with `error.InsecureFile`. The checks run on the opened
/// handle, so a path swapped after the check is never read.
///
/// ```zig
/// const bytes = try private_file.read(io, gpa, path, .limited(64 * 1024)) orelse return .{};
/// defer gpa.free(bytes);
/// ```
pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: std.Io.Limit) !?[]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.IsDir => return error.InsecureFile,
        else => |other| return other,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & @intFromEnum(Mode.shared) != 0) {
        return error.InsecureFile;
    }

    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |other| return other,
    };
}

/// Replaces `path` with `content` atomically: the bytes go to an owner-only
/// temporary file beside it, reach the disk, then take its name. Its
/// directory is created owner-only when missing. Readers see the old file or
/// the new one, never a partial write.
///
/// ```zig
/// try private_file.replace(io, path, json);
/// ```
pub fn replace(io: std.Io, path: []const u8, content: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse return error.InvalidPrivatePath;
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, directory, .fromMode(@intFromEnum(Mode.directory)));
    try cwd.setFilePermissions(io, directory, .fromMode(@intFromEnum(Mode.directory)), .{ .follow_symlinks = false });

    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp-{s}", .{ path, &nonce_hex });
    var committed = false;
    defer if (!committed) {
        cwd.deleteFile(io, temporary) catch {};
    };

    var file = try cwd.createFile(io, temporary, .{
        .truncate = true,
        .exclusive = true,
        .permissions = .fromMode(@intFromEnum(Mode.file)),
    });
    var open = true;
    defer if (open) {
        file.close(io);
    };

    try file.writeStreamingAll(io, content);
    try file.sync(io);
    file.close(io);
    open = false;

    try cwd.rename(temporary, cwd, path, io);
    committed = true;
}

/// Summarizes what a poller needs to notice a change: the path, and the
/// kind, size and modification time of what is there, or its absence. It
/// does not read the file.
///
/// ```zig
/// if (private_file.fingerprint(io, path, seed) != known) reload();
/// ```
pub fn fingerprint(io: std.Io, path: []const u8, seed: u64) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
        hasher.update("\x00missing");
        return hasher.final();
    };

    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    return hasher.final();
}

fn temporaryPath(temp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory_buffer[0..directory_len], name });
}

test "a replaced file is private, whole and readable back" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "config/telar/machines.json", &path_buffer);

    try replace(std.testing.io, path, "{\"version\":1}\n");
    try replace(std.testing.io, path, "{\"version\":2}\n");

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@intFromEnum(Mode.file), stat.permissions.toMode() & 0o777);

    const directory = try std.Io.Dir.cwd().statFile(std.testing.io, std.fs.path.dirname(path).?, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@intFromEnum(Mode.directory), directory.permissions.toMode() & 0o777);

    const bytes = (try read(std.testing.io, std.testing.allocator, path, .limited(1024))).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"version\":2}\n", bytes);
}

test "a missing file reads as null and changes its fingerprint when created" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "absent.json", &path_buffer);

    try std.testing.expectEqual(@as(?[]u8, null), try read(std.testing.io, std.testing.allocator, path, .limited(64)));

    const before = fingerprint(std.testing.io, path, 7);
    try replace(std.testing.io, path, "{}");
    try std.testing.expect(before != fingerprint(std.testing.io, path, 7));
}

test "shared files, symlinks and oversized files are refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "shared.json", &path_buffer);
    try replace(std.testing.io, path, "{}");
    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, path, .fromMode(0o640), .{ .follow_symlinks = false });
    try std.testing.expectError(error.InsecureFile, read(std.testing.io, std.testing.allocator, path, .limited(64)));

    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link = try temporaryPath(&temp, "link.json", &link_buffer);
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = try temporaryPath(&temp, "target.json", &target_buffer);
    try replace(std.testing.io, target, "{}");
    try std.Io.Dir.cwd().symLink(std.testing.io, target, link, .{});
    try std.testing.expectError(error.InsecureFile, read(std.testing.io, std.testing.allocator, link, .limited(64)));

    try std.testing.expectError(error.StreamTooLong, read(std.testing.io, std.testing.allocator, target, .limited(1)));
}
