//! Backend ownership of the filesystem-backed Unix listener.

const std = @import("std");
const builtin = @import("builtin");
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
            // SAFETY: getsockopt fills credentials; both success and the exact output size are checked before reading uid.
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
            // SAFETY: getpeereid writes uid on success; its failure returns before uid is read.
            var uid: c.uid_t = undefined;
            // SAFETY: getpeereid receives gid as an output parameter; this function never reads it.
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
/// reports it: `LOCAL_PEERPID` on macOS, `SO_PEERCRED` on Linux. A socket
/// shared by several processes may name any of them; a connection its
/// process opened and keeps to itself names that process.
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
            // SAFETY: getsockopt fills credentials; short-circuit checks reject failure or a short result before reading pid.
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
    if (path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) {
        return error.NameTooLong;
    }
    return std.Io.net.UnixAddress.init(path);
}

/// Serializes stale probing, bind and listen so a bound socket is never reclaimed
/// before its creating runtime calls listen. Example: `const held = try lockEndpoint(io, path);`.
pub fn lockEndpoint(io: std.Io, path: []const u8) !std.Io.File {
    var directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse return error.RelativePath, .{ .follow_symlinks = false });
    defer directory.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "{s}.lock", .{std.fs.path.basename(path)});
    return privatefile.lockAt(io, directory, name);
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

    // SAFETY: memset initializes the entire path before it is passed to connect.
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
