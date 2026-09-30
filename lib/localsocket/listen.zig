//! Backend ownership of the filesystem-backed Unix listener.

const std = @import("std");
const SocketDirectory = @import("SocketDirectory.zig");
const builtin = @import("builtin");
const LocalListener = @import("LocalListener.zig");
const privatefile = @import("privatefile");

const Inode = privatefile.Inode;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub fn sameUserPeer(peer_uid: u32, effective_uid: u32) bool {
    return peer_uid == effective_uid;
}

pub fn peerUid(handle: std.c.fd_t) !u32 {
    return switch (builtin.os.tag) {
        .linux => linux: {
            const Credentials = extern struct {
                pid: i32,
                uid: u32,
                gid: u32,
            };
            var credentials: Credentials = undefined;
            var len: std.os.linux.socklen_t = @sizeOf(Credentials);
            const result = std.os.linux.getsockopt(
                handle,
                std.os.linux.SOL.SOCKET,
                std.os.linux.SO.PEERCRED,
                @ptrCast(&credentials),
                &len,
            );
            if (std.posix.errno(result) != .SUCCESS or len != @sizeOf(Credentials)) {
                return error.PeerCredentialsUnavailable;
            }
            break :linux credentials.uid;
        },
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => bsd: {
            var uid: c.uid_t = undefined;
            var gid: c.gid_t = undefined;
            if (c.getpeereid(handle, &uid, &gid) != 0) {
                return error.PeerCredentialsUnavailable;
            }
            break :bsd @intCast(uid);
        },
        else => @compileError("local peer authentication is unsupported on this platform"),
    };
}

/// The process at the other end of a connected local socket, as the kernel
/// recorded it when the connection was made: `LOCAL_PEERPID` on macOS,
/// `SO_PEERCRED` on Linux.
///
/// ```zig
/// const pid = try peerProcess(handle);
/// ```
pub fn peerProcess(handle: std.c.fd_t) !u32 {
    return switch (builtin.os.tag) {
        .linux => linux: {
            const Credentials = extern struct {
                pid: i32,
                uid: u32,
                gid: u32,
            };
            var credentials: Credentials = undefined;
            var len: std.os.linux.socklen_t = @sizeOf(Credentials);
            const result = std.os.linux.getsockopt(
                handle,
                std.os.linux.SOL.SOCKET,
                std.os.linux.SO.PEERCRED,
                @ptrCast(&credentials),
                &len,
            );
            if (std.posix.errno(result) != .SUCCESS or len != @sizeOf(Credentials) or credentials.pid <= 0) {
                return error.PeerCredentialsUnavailable;
            }

            break :linux @intCast(credentials.pid);
        },
        .macos => macos: {
            var pid: c.pid_t = 0;
            var len: c.socklen_t = @sizeOf(c.pid_t);
            if (c.getsockopt(handle, c.SOL_LOCAL, c.LOCAL_PEERPID, &pid, &len) != 0 or len != @sizeOf(c.pid_t) or pid <= 0) {
                return error.PeerCredentialsUnavailable;
            }

            break :macos @intCast(pid);
        },
        else => error.PeerCredentialsUnavailable,
    };
}

pub const DirectoryTrust = enum {
    trusted,
    not_a_directory,
    wrong_owner,
    group_or_world_writable,
};

/// Classifies whether an endpoint's directory can be trusted to hold it.
///
/// The socket file itself is 0600, so connecting already requires owning it;
/// what a hostile same-machine account needs is *write* permission on the
/// directory, which lets it unlink and replace the endpoint. Owner mismatch
/// or group/other write bits are therefore fatal. Read and traverse bits are
/// tolerated - they reveal the endpoint's name, never its traffic - so
/// conventional 0755 state directories keep working.
// Universal POSIX mode bits, so the classifier needs no OS-specific types.
const mode_format_mask: u32 = 0o170000;
const mode_directory: u32 = 0o040000;

pub fn classifyEndpointDirectory(mode: u32, uid: u32, euid: u32) DirectoryTrust {
    if (mode & mode_format_mask != mode_directory) {
        return .not_a_directory;
    }
    if (uid != euid) {
        return .wrong_owner;
    }
    if (mode & 0o022 != 0) {
        return .group_or_world_writable;
    }
    return .trusted;
}

pub fn validateEndpointDirectory(path: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse return error.RelativePath;
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (directory.len >= directory_buffer.len) {
        return error.NameTooLong;
    }
    @memcpy(directory_buffer[0..directory.len], directory);
    directory_buffer[directory.len] = 0;
    const directory_z = directory_buffer[0..directory.len :0];

    return switch (try directoryTrust(directory_z)) {
        .trusted => {},
        .not_a_directory => error.InvalidEndpoint,
        .wrong_owner => error.EndpointDirectoryNotOwned,
        .group_or_world_writable => error.EndpointDirectoryWritable,
    };
}

fn directoryTrust(path: [:0]const u8) !DirectoryTrust {
    const inode = Inode.fromPath(path, .no_follow) catch return error.InvalidEndpoint;
    return classifyEndpointDirectory(inode.mode, inode.owner, std.c.geteuid());
}

pub fn localAddress(path: []const u8) !std.Io.net.UnixAddress {
    if (!std.fs.path.isAbsolute(path)) {
        return error.RelativePath;
    }
    const native_address: std.c.sockaddr.un = .{ .path = undefined };
    if (path.len >= native_address.path.len) {
        return error.NameTooLong;
    }
    return std.Io.net.UnixAddress.init(path);
}

/// A filesystem socket survives a process crash. Probe it before unlinking and
/// remove it only when connect reports that no listener exists and the inode
/// still matches the one inspected before the probe.
pub fn reclaimStaleEndpoint(io: std.Io, path: []const u8) !void {
    const original = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    if (original.kind != .unix_domain_socket) {
        return error.InvalidEndpoint;
    }

    const socket = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (socket < 0) {
        return error.ProbeFailed;
    }
    defer _ = std.c.close(socket);

    var address: std.c.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    std.mem.copyForwards(u8, address.path[0..path.len], path);

    while (true) {
        const result = std.c.connect(
            socket,
            @ptrCast(&address),
            @intCast(@sizeOf(std.c.sockaddr.un)),
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => return error.AddressInUse,
            .INTR => continue,
            .CONNREFUSED, .NOENT => {
                const current = std.Io.Dir.cwd().statFile(
                    io,
                    path,
                    .{ .follow_symlinks = false },
                ) catch return;
                if (current.kind != .unix_domain_socket or current.inode != original.inode) {
                    return error.EndpointChanged;
                }
                try std.Io.Dir.deleteFileAbsolute(io, path);
                return;
            },
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.ProbeFailed,
        }
    }
}

test "endpoint directory trust classification" {
    const euid: u32 = 1000;
    try std.testing.expectEqual(
        DirectoryTrust.trusted,
        classifyEndpointDirectory(mode_directory | 0o700, 1000, euid),
    );
    try std.testing.expectEqual(
        DirectoryTrust.trusted,
        classifyEndpointDirectory(mode_directory | 0o755, 1000, euid),
    );
    try std.testing.expectEqual(
        DirectoryTrust.group_or_world_writable,
        classifyEndpointDirectory(mode_directory | 0o775, 1000, euid),
    );
    try std.testing.expectEqual(
        DirectoryTrust.group_or_world_writable,
        classifyEndpointDirectory(mode_directory | 0o777, 1000, euid),
    );
    try std.testing.expectEqual(
        DirectoryTrust.wrong_owner,
        classifyEndpointDirectory(mode_directory | 0o700, 1001, euid),
    );
    try std.testing.expectEqual(
        DirectoryTrust.not_a_directory,
        classifyEndpointDirectory(0o100600, 1000, euid),
    );
}

test "peer authentication rejects a different account" {
    try std.testing.expect(sameUserPeer(1000, 1000));
    try std.testing.expect(!sameUserPeer(1001, 1000));
}

test "a listener refuses a directory another account could rewrite" {
    const io = std.testing.io;
    var temp = try SocketDirectory.create(io);
    defer temp.cleanup(io);

    var shared_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const shared = try std.fmt.bufPrintZ(
        &shared_buffer,
        "{s}/shared",
        .{temp.path()},
    );
    try std.Io.Dir.createDirAbsolute(io, shared, std.Io.File.Permissions.fromMode(0o777));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(shared, 0o777));

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/exposed.sock", .{shared});
    try std.testing.expectError(
        error.EndpointDirectoryWritable,
        LocalListener.listen(io, path),
    );
}

test "a listener refuses a symlink as its endpoint directory" {
    const io = std.testing.io;
    var temp = try SocketDirectory.create(io);
    defer temp.cleanup(io);

    try temp.dir.createDir(io, "real", std.Io.File.Permissions.fromMode(0o700));
    try temp.dir.symLink(io, "real", "alias", .{ .is_directory = true });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/alias/runtime.sock", .{temp.path()});

    try std.testing.expectError(error.InvalidEndpoint, LocalListener.listen(io, path));
}

test "a listener reclaims a socket left behind by a crashed process" {
    const io = std.testing.io;
    var temp = try SocketDirectory.create(io);
    defer temp.cleanup(io);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/stale.sock",
        .{temp.path()},
    );

    const address = try localAddress(path);
    var abandoned = try address.listen(io, .{});
    abandoned.deinit(io);

    var listener = try LocalListener.listen(io, path);
    listener.deinit(io);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }),
    );
}

test "the peer of a socket pair is the process that made it" {
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);

    try std.testing.expectEqual(@as(u32, @intCast(std.c.getpid())), try peerProcess(sockets[0]));
}
