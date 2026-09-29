//! A private temporary directory for tests that bind Unix sockets.
//!
//! A socket's path must fit `sun_path`: 104 bytes on macOS, 108 on Linux.
//! `std.testing.tmpDir` nests under the checkout's `.zig-cache`, so a
//! checkout a few directories deep leaves no room for the socket's name, and
//! `$TMPDIR` is just as deep on macOS. This directory sits right under
//! `/tmp`, whose path is short on every Unix wherever the checkout lives.
const std = @import("std");
const SocketDirectory = @This();

const parent_path = "/tmp";
const name_prefix = "telar-test-";
const random_bytes_count = 9;
const name_len = name_prefix.len + std.base64.url_safe.Encoder.calcSize(random_bytes_count);

/// The directory, open for the files a test keeps beside its sockets.
dir: std.Io.Dir,
parent: std.Io.Dir,
name: [name_len]u8,
/// The real path, since `/tmp` is a symlink on macOS.
path_buffer: [std.fs.max_path_bytes]u8,
path_len: usize,

/// Creates the directory, open to this user only. The caller calls
/// `cleanup`, which removes it with everything inside.
///
/// ```zig
/// var sockets = try SocketDirectory.create(io);
/// defer sockets.cleanup(io);
/// var buffer: [std.fs.max_path_bytes]u8 = undefined;
/// const endpoint = try sockets.endpoint(&buffer, "runtime.sock");
/// ```
pub fn create(io: std.Io) !SocketDirectory {
    var self: SocketDirectory = undefined;
    var random_bytes: [random_bytes_count]u8 = undefined;
    io.random(&random_bytes);
    @memcpy(self.name[0..name_prefix.len], name_prefix);
    _ = std.base64.url_safe.Encoder.encode(self.name[name_prefix.len..], &random_bytes);

    self.parent = try std.Io.Dir.openDirAbsolute(io, parent_path, .{});
    errdefer self.parent.close(io);

    try self.parent.createDir(io, &self.name, .fromMode(0o700));
    errdefer self.parent.deleteTree(io, &self.name) catch {};

    self.dir = try self.parent.openDir(io, &self.name, .{});
    errdefer self.dir.close(io);

    self.path_len = try self.dir.realPath(io, &self.path_buffer);
    return self;
}

pub fn path(self: *const SocketDirectory) []const u8 {
    return self.path_buffer[0..self.path_len];
}

/// The path of `name` inside the directory, written into `buffer`.
///
/// ```zig
/// const endpoint = try sockets.endpoint(&buffer, "runtime.sock");
/// ```
pub fn endpoint(self: *const SocketDirectory, buffer: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path(), name });
}

pub fn cleanup(self: *SocketDirectory, io: std.Io) void {
    self.dir.close(io);
    self.parent.deleteTree(io, &self.name) catch {};
    self.parent.close(io);
    self.* = undefined;
}

test "a socket directory leaves room for a 64-byte socket name wherever the checkout is" {
    const io = std.testing.io;
    var sockets = try create(io);
    defer sockets.cleanup(io);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket_name = "s" ** 59 ++ ".sock";
    const socket_path = try sockets.endpoint(&buffer, socket_name);
    const address: std.c.sockaddr.un = .{ .path = undefined };
    try std.testing.expect(socket_path.len < address.path.len);

    const stat = try sockets.parent.statFile(io, &sockets.name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(stat.permissions.toMode())) & 0o077);
}

test "cleanup removes the directory and what it holds" {
    const io = std.testing.io;
    var sockets = try create(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const kept = try std.fmt.bufPrint(&buffer, "{s}", .{sockets.path()});
    try sockets.dir.writeFile(io, .{
        .sub_path = "left.log",
        .data = "x",
    });

    sockets.cleanup(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, kept, .{ .follow_symlinks = false }));
}
