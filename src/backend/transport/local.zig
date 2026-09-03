//! Backend ownership of the filesystem-backed Unix listener.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const core = @import("telar-core");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

pub const LocalListener = struct {
    listener: Io.net.Server,
    path: [Io.net.UnixAddress.max_len]u8 = undefined,
    path_len: usize,
    inode: Io.File.INode,
    active: bool = true,

    pub fn listen(io: Io, path: []const u8) !LocalListener {
        const address = try localAddress(path);
        try validateEndpointDirectory(path);
        try reclaimStaleEndpoint(io, path);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);

        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .unix_domain_socket) {
            return error.InvalidEndpoint;
        }
        errdefer removeIfOwned(io, path, stat.inode);

        // The chmod must go through the path: a Unix socket descriptor does
        // not reference the filesystem node that carries the mode, so fchmod
        // cannot restrict the endpoint. Renaming it out from under us in this
        // window requires write permission on the directory, which the trust
        // validation above already refused to anyone but the owner.
        try Io.Dir.cwd().setFilePermissions(
            io,
            path,
            Io.File.Permissions.fromMode(0o600),
            .{ .follow_symlinks = false },
        );

        var result = LocalListener{
            .listener = listener,
            .path_len = path.len,
            .inode = stat.inode,
        };
        std.mem.copyForwards(u8, result.path[0..path.len], path);
        return result;
    }

    pub fn accept(listener: *LocalListener, io: Io) !core.transport.SocketChannel {
        std.debug.assert(listener.active);
        const stream = try listener.listener.accept(io);
        errdefer stream.close(io);
        const peer_uid = try peerUid(stream.socket.handle);
        if (!sameUserPeer(peer_uid, std.c.geteuid())) {
            return error.PeerNotOwned;
        }
        return .init(stream);
    }

    pub fn deinit(listener: *LocalListener, io: Io) void {
        if (!listener.active) {
            return;
        }
        // POSIX does not guarantee that close from another thread interrupts
        // accept. Shutdown does, and the runtime admission actor uses it as
        // the concurrent cancellation mechanism.
        listener.shutdown();
        listener.listener.deinit(io);
        removeIfOwned(io, listener.path[0..listener.path_len], listener.inode);
        listener.active = false;
    }

    pub fn shutdown(listener: *LocalListener) void {
        if (!listener.active) {
            return;
        }
        _ = std.c.shutdown(listener.listener.socket.handle, std.posix.SHUT.RDWR);
    }

    fn removeIfOwned(io: Io, path: []const u8, inode: Io.File.INode) void {
        const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
        if (stat.kind != .unix_domain_socket or stat.inode != inode) {
            return;
        }
        Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
};

pub fn sameUserPeer(peer_uid: u32, effective_uid: u32) bool {
    return peer_uid == effective_uid;
}

fn peerUid(handle: std.c.fd_t) !u32 {
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

fn validateEndpointDirectory(path: []const u8) !void {
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
    switch (builtin.os.tag) {
        .linux => {
            var stat: std.os.linux.Stat = undefined;
            if (std.os.linux.stat(path, &stat) != 0) {
                return error.InvalidEndpoint;
            }
            return classifyEndpointDirectory(
                @intCast(stat.mode),
                @intCast(stat.uid),
                @intCast(std.os.linux.geteuid()),
            );
        },
        else => {
            // `std.c` exposes no plain `stat`; go through a descriptor.
            const fd = std.c.open(path, .{});
            if (fd < 0) {
                return error.InvalidEndpoint;
            }
            defer _ = std.c.close(fd);
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat) != 0) {
                return error.InvalidEndpoint;
            }
            return classifyEndpointDirectory(
                @intCast(stat.mode),
                @intCast(stat.uid),
                @intCast(std.c.geteuid()),
            );
        },
    }
}

fn localAddress(path: []const u8) !Io.net.UnixAddress {
    if (!std.fs.path.isAbsolute(path)) {
        return error.RelativePath;
    }
    const native_address: std.c.sockaddr.un = .{ .path = undefined };
    if (path.len >= native_address.path.len) {
        return error.NameTooLong;
    }
    return Io.net.UnixAddress.init(path);
}

/// A filesystem socket survives a process crash. Probe it before unlinking and
/// remove it only when connect reports that no listener exists and the inode
/// still matches the one inspected before the probe.
fn reclaimStaleEndpoint(io: Io, path: []const u8) !void {
    const original = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
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
                const current = Io.Dir.cwd().statFile(
                    io,
                    path,
                    .{ .follow_symlinks = false },
                ) catch return;
                if (current.kind != .unix_domain_socket or current.inode != original.inode) {
                    return error.EndpointChanged;
                }
                try Io.Dir.deleteFileAbsolute(io, path);
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
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var shared_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const shared = try std.fmt.bufPrintZ(
        &shared_buffer,
        "{s}/shared",
        .{directory_buffer[0..directory_len]},
    );
    try Io.Dir.createDirAbsolute(io, shared, Io.File.Permissions.fromMode(0o777));
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(shared, 0o777));

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/exposed.sock", .{shared});
    try std.testing.expectError(
        error.EndpointDirectoryWritable,
        LocalListener.listen(io, path),
    );
}

test "a listener reclaims a socket left behind by a crashed process" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/stale.sock",
        .{directory_buffer[0..directory_len]},
    );

    const address = try localAddress(path);
    var abandoned = try address.listen(io, .{});
    abandoned.deinit(io);

    var listener = try LocalListener.listen(io, path);
    listener.deinit(io);
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }),
    );
}
