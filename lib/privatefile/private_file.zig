const std = @import("std");
const Inode = @import("Inode.zig");

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
    try prepareParent(io, path);
    const cwd = std.Io.Dir.cwd();

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

/// Takes an exclusive lock over `path` for one read, change and replace,
/// so two processes or threads never both read the old file and each
/// replace it without the other's change. The lock is flock(2) on
/// `<path>.lock`, an owner-only file beside it that stays when released,
/// because removing a locked file would let a second caller lock a new one.
/// A caller waits while another holds it, and closing the returned file
/// releases it, as does the process ending.
///
/// ```zig
/// const held = try private_file.lock(io, path);
/// defer held.close(io);
/// const bytes = try private_file.read(io, gpa, path, limit);
/// try private_file.replace(io, path, changed);
/// ```
pub fn lock(io: std.Io, path: []const u8) !std.Io.File {
    try prepareParent(io, path);

    var lock_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buffer, "{s}.lock", .{path});
    const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(@intFromEnum(Mode.file)),
    });
    errdefer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & @intFromEnum(Mode.shared) != 0) {
        return error.InsecureFile;
    }

    return file;
}

/// Locks one private regular file in an already owned directory without following links.
/// The inode stays after release so competing callers always lock the same file.
/// Example: `const held = try lockAt(io, directory, "runtime.sock.lock");`.
pub fn lockAt(io: std.Io, directory: std.Io.Dir, name: []const u8) !std.Io.File {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidPrivatePath;
    }

    const parent = try Inode.fromDescriptor(directory.handle);
    if (parent.kind() != .directory or parent.owner != std.c.getuid() or parent.mode & 0o022 != 0) {
        return error.InsecureDirectory;
    }

    const file = directory.createFile(io, name, .{ .exclusive = true, .read = true, .permissions = .fromMode(@intFromEnum(Mode.file)) }) catch |err| blk: {
        if (err != error.PathAlreadyExists) {
            return err;
        }

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
        const fd = std.posix.openatZ(directory.handle, name_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0) catch |failure| switch (failure) {
            error.SymLinkLoop => return error.InsecureFile,
            else => return failure,
        };
        break :blk std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } };
    };
    errdefer file.close(io);
    const inode = try Inode.fromDescriptor(file.handle);
    if (inode.kind() != .regular or inode.owner != std.c.getuid() or inode.links != 1 or inode.mode & @intFromEnum(Mode.shared) != 0) {
        return error.InsecureFile;
    }

    try file.lock(io, .exclusive);
    return file;
}

// Creates the parent of `path` owner-only when missing, and resets its
// permissions when it exists.
fn prepareParent(io: std.Io, path: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse return error.InvalidPrivatePath;
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, directory, .fromMode(@intFromEnum(Mode.directory)));
    try cwd.setFilePermissions(io, directory, .fromMode(@intFromEnum(Mode.directory)), .{ .follow_symlinks = false });
}

/// Makes `path` an owner-only directory: created when missing, refused
/// unless it is a real directory the current user owns, then reset to
/// owner-only permissions. A directory someone else owns is where another
/// user could plant a socket or a file, so it is never adopted.
///
/// ```zig
/// try private_file.prepareDirectory(io, "/run/user/1000/telar");
/// ```
pub fn prepareDirectory(io: std.Io, path: []const u8) !void {
    const permissions: std.Io.File.Permissions = .fromMode(@intFromEnum(Mode.directory));
    std.Io.Dir.createDirAbsolute(io, path, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return other,
    };

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{path}) catch return error.NameTooLong;
    const inode = Inode.fromPath(path_z, .no_follow) catch return error.InsecureDirectory;
    if (inode.kind() != .directory) {
        return error.InsecureDirectory;
    }

    try requireOwner(inode.owner, std.c.getuid());
    try std.Io.Dir.cwd().setFilePermissions(io, path, permissions, .{ .follow_symlinks = false });
}

fn requireOwner(owner: std.c.uid_t, current_user: std.c.uid_t) error{WrongOwner}!void {
    if (owner != current_user) {
        return error.WrongOwner;
    }
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

test "a prepared directory is owner-only and a file in its place is refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "runtime", &path_buffer);
    try prepareDirectory(std.testing.io, path);
    try prepareDirectory(std.testing.io, path);

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@intFromEnum(Mode.directory), stat.permissions.toMode() & 0o777);

    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try temporaryPath(&temp, "not-a-directory", &file_buffer);
    try replace(std.testing.io, file, "{}");
    try std.testing.expectError(error.InsecureDirectory, prepareDirectory(std.testing.io, file));
}

test "a lock is owner-only, excludes a second holder and outlives its release" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&temp, "config/machines.json", &path_buffer);

    const held = try lock(std.testing.io, path);
    var lock_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buffer, "{s}.lock", .{path});
    const second = try std.Io.Dir.cwd().openFile(std.testing.io, lock_path, .{ .mode = .read_write });
    defer second.close(std.testing.io);
    try std.testing.expect(!try second.tryLock(std.testing.io, .exclusive));

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, lock_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@intFromEnum(Mode.file), stat.permissions.toMode() & 0o777);

    held.close(std.testing.io);
    try std.testing.expect(try second.tryLock(std.testing.io, .exclusive));
}

test "a directory must belong to the current user" {
    try requireOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, requireOwner(0, 1000));
}
