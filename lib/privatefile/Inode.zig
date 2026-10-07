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

/// The fields `statx` must return; a reply missing any is refused.
const request: linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .NLINK = true,
    .UID = true,
    .SIZE = true,
};

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
        const no_follow: u32 = if (links == .no_follow) linux.AT.SYMLINK_NOFOLLOW else 0;
        return statx(linux.AT.FDCWD, path, linux.AT.NO_AUTOMOUNT | no_follow);
    }

    const flags: u32 = if (links == .no_follow) std.c.AT.SYMLINK_NOFOLLOW else 0;
    // SAFETY: fstatat fills stat on success; only the SUCCESS branch passes it to fromStat.
    var stat: std.c.Stat = undefined;
    while (true) {
        switch (std.posix.errno(std.c.fstatat(std.c.AT.FDCWD, path, &stat, flags))) {
            .SUCCESS => return fromStat(stat),
            .INTR => continue,
            else => return error.InodeUnavailable,
        }
    }
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

    // SAFETY: fstat fills stat on success; only the SUCCESS branch passes it to fromStat.
    var stat: std.c.Stat = undefined;
    while (true) {
        switch (std.posix.errno(std.c.fstat(fd, &stat))) {
            .SUCCESS => return fromStat(stat),
            .INTR => continue,
            else => return error.InodeUnavailable,
        }
    }
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

// Retries an interrupted call, as `std.Io` does.
fn statx(directory: std.posix.fd_t, path: [*:0]const u8, flags: u32) error{InodeUnavailable}!Inode {
    while (true) {
        var buffer = std.mem.zeroes(linux.Statx);
        switch (linux.errno(linux.statx(directory, path, flags, request, &buffer))) {
            .SUCCESS => return fromStatx(buffer),
            .INTR => continue,
            else => return error.InodeUnavailable,
        }
    }
}

// A file system may leave out fields it cannot provide; `stx_mask` says
// which it filled, and an ownership check must not read a zero as root.
fn fromStatx(buffer: linux.Statx) error{InodeUnavailable}!Inode {
    const returned: u32 = @bitCast(buffer.mask);
    const wanted: u32 = @bitCast(request);
    if (returned & wanted != wanted) {
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
