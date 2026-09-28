//! What an ownership check reads from an inode: its type and permission
//! bits, owner, link count and size. Linux asks `statx` directly, as
//! `std.Io` does, so every libc sees the same layout; musl's `struct stat`
//! cannot be imported through `@cImport` at all, because its `timespec`
//! pads with bit-fields.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const Inode = @This();

mode: u32,
owner: std.posix.uid_t,
links: u64,
size: u64,

/// Whether `fromPath` reports a symlink itself or the file it points to.
pub const Links = enum {
    follow,
    no_follow,
};

/// The file type bits of `mode`.
pub const Kind = enum(u32) {
    directory = 0o040000,
    regular = 0o100000,
    socket = 0o140000,
    _,
};

const kind_mask: u32 = 0o170000;

/// Reads the inode at `path`. Fails when it does not exist or cannot be read.
///
/// ```zig
/// const inode = try Inode.fromPath(path_z, .no_follow);
/// if (inode.kind() != .directory or inode.owner != std.c.getuid()) {
///     return error.InsecureDirectory;
/// }
/// ```
pub fn fromPath(path: [*:0]const u8, links: Links) error{InodeUnavailable}!Inode {
    if (builtin.os.tag == .linux) {
        const flags: u32 = if (links == .no_follow) linux.AT.SYMLINK_NOFOLLOW else 0;
        return statx(linux.AT.FDCWD, path, flags);
    }

    const flags: u32 = if (links == .no_follow) std.c.AT.SYMLINK_NOFOLLOW else 0;
    var stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &stat, flags) != 0) {
        return error.InodeUnavailable;
    }

    return fromStat(stat);
}

/// Reads the inode behind an open descriptor, so a path swapped after the
/// open is never what gets checked.
///
/// ```zig
/// const inode = try Inode.fromDescriptor(fd);
/// if (inode.kind() != .regular or inode.size < byte_len) {
///     return null;
/// }
/// ```
pub fn fromDescriptor(fd: std.posix.fd_t) error{InodeUnavailable}!Inode {
    if (builtin.os.tag == .linux) {
        return statx(fd, "", linux.AT.EMPTY_PATH);
    }

    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) {
        return error.InodeUnavailable;
    }

    return fromStat(stat);
}

/// The file type, from the type bits of `mode`.
///
/// ```zig
/// if (inode.kind() != .regular) {
///     return error.InsecureFile;
/// }
/// ```
pub fn kind(self: Inode) Kind {
    return @enumFromInt(self.mode & kind_mask);
}

fn statx(directory: std.posix.fd_t, path: [*:0]const u8, flags: u32) error{InodeUnavailable}!Inode {
    const request: linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .SIZE = true,
    };
    var buffer: linux.Statx = undefined;
    if (linux.errno(linux.statx(directory, path, flags, request, &buffer)) != .SUCCESS) {
        return error.InodeUnavailable;
    }

    return .{
        .mode = buffer.mode,
        .owner = buffer.uid,
        .links = buffer.nlink,
        .size = buffer.size,
    };
}

fn fromStat(stat: std.c.Stat) Inode {
    return .{
        .mode = stat.mode,
        .owner = stat.uid,
        .links = stat.nlink,
        .size = @intCast(@max(stat.size, 0)),
    };
}

fn temporaryPath(temp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![:0]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ directory_buffer[0..directory_len], name });
}

test "a path reports its type, owner, links and size, and a symlink is not followed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const io = std.testing.io;
    try temp.dir.writeFile(io, .{
        .sub_path = "file",
        .data = "four",
    });
    try temp.dir.symLink(io, "file", "link", .{});

    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try fromPath(try temporaryPath(&temp, "file", &file_buffer), .no_follow);
    try std.testing.expectEqual(Kind.regular, file.kind());
    try std.testing.expectEqual(std.c.getuid(), file.owner);
    try std.testing.expectEqual(@as(u64, 1), file.links);
    try std.testing.expectEqual(@as(u64, 4), file.size);

    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try temporaryPath(&temp, "link", &link_buffer);
    const link = try fromPath(link_path, .no_follow);
    try std.testing.expect(link.kind() != .regular);

    const target = try fromPath(link_path, .follow);
    try std.testing.expectEqual(Kind.regular, target.kind());
}

test "a descriptor reports the file it was opened on" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const io = std.testing.io;
    try temp.dir.writeFile(io, .{
        .sub_path = "file",
        .data = "eight by",
    });

    const file = try temp.dir.openFile(io, "file", .{});
    defer file.close(io);

    const inode = try fromDescriptor(file.handle);
    try std.testing.expectEqual(Kind.regular, inode.kind());
    try std.testing.expectEqual(@as(u64, 8), inode.size);
    try std.testing.expectEqual(std.c.getuid(), inode.owner);
}

test "a missing path is unavailable" {
    try std.testing.expectError(error.InodeUnavailable, fromPath("/nonexistent/telar-inode-test", .no_follow));
}
