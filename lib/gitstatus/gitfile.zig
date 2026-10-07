//! The small files Git keeps beside a checkout (`.git`, `HEAD`, `commondir`),
//! read without trusting them: whoever made the directory chose what they
//! are. Anything but a regular file is refused before a read could block on
//! it, and a relative `gitdir:` (Git's `worktree.useRelativePaths`) is
//! resolved against the directory holding the `.git` file.
const std = @import("std");
const builtin = @import("builtin");

/// Reads the regular file at `path` into `buffer`. A FIFO, device, socket
/// or directory is refused without waiting: the file is opened non-blocking
/// and checked through its descriptor, so it cannot be swapped between the
/// check and the read.
///
/// ```zig
/// var head: [256]u8 = undefined;
/// const bytes = gitfile.readRegular(io, "/src/telar/.git/HEAD", &head) orelse return null;
/// ```
pub fn readRegular(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    const file = openWithoutBlocking(io, path) orelse return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.kind != .file) {
        return null;
    }

    var reader = file.readerStreaming(io, &.{});
    const len = reader.interface.readSliceShort(buffer) catch return null;
    return buffer[0..len];
}

/// Opens `path` for reading. On POSIX the open itself never waits, even on
/// a FIFO nobody writes to; Windows has no such file to wait on.
fn openWithoutBlocking(io: std.Io, path: []const u8) ?std.Io.File {
    if (comptime builtin.os.tag == .windows) {
        return std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
    }

    const flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    };
    const handle = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0) catch return null;
    return .{
        .handle = handle,
        .flags = .{ .nonblocking = true },
    };
}

/// The git dir a `.git` file at `dot_git_path` names, absolute when the
/// file's own path is. Null when it is not a readable regular file starting
/// with `gitdir:`.
///
/// ```zig
/// var git_dir: [std.fs.max_path_bytes]u8 = undefined;
/// const dir = gitfile.gitDir(io, "/src/telar-worktrees/fix/.git", &git_dir) orelse return null;
/// ```
pub fn gitDir(io: std.Io, dot_git_path: []const u8, buffer: []u8) ?[]const u8 {
    var contents_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const contents = std.mem.trim(u8, readRegular(io, dot_git_path, &contents_buffer) orelse return null, " \t\r\n");
    if (!std.mem.startsWith(u8, contents, "gitdir:")) {
        return null;
    }

    const named = std.mem.trim(u8, contents["gitdir:".len..], " \t");
    return resolve(std.fs.path.dirname(dot_git_path) orelse return null, named, buffer);
}

/// `path` as it is when absolute, else joined to `base`.
///
/// ```zig
/// const common = gitfile.resolve(git_dir, "../..", &buffer) orelse return null;
/// ```
pub fn resolve(base: []const u8, path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
        return null;
    }

    if (std.fs.path.isAbsolute(path)) {
        if (path.len > buffer.len) {
            return null;
        }

        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), path }) catch null;
}
