//! Backend ownership of the filesystem-backed Unix listener.

const std = @import("std");
const Io = std.Io;
const core = @import("telar-core");

pub const LocalListener = struct {
    listener: Io.net.Server,
    path: [Io.net.UnixAddress.max_len]u8 = undefined,
    path_len: usize,
    inode: Io.File.INode,
    active: bool = true,

    pub fn listen(io: Io, path: []const u8) !LocalListener {
        const address = try localAddress(path);
        try reclaimStaleEndpoint(io, path);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);

        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .unix_domain_socket) return error.InvalidEndpoint;
        errdefer removeIfOwned(io, path, stat.inode);

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
        return .init(try listener.listener.accept(io));
    }

    pub fn deinit(listener: *LocalListener, io: Io) void {
        if (!listener.active) return;
        // POSIX does not guarantee that close from another thread interrupts
        // accept. Shutdown does, and Server.accept documents it as the
        // concurrent cancellation mechanism.
        _ = std.c.shutdown(listener.listener.socket.handle, std.posix.SHUT.RDWR);
        listener.listener.deinit(io);
        removeIfOwned(io, listener.path[0..listener.path_len], listener.inode);
        listener.active = false;
    }

    fn removeIfOwned(io: Io, path: []const u8, inode: Io.File.INode) void {
        const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
        if (stat.kind != .unix_domain_socket or stat.inode != inode) return;
        Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
};

fn localAddress(path: []const u8) !Io.net.UnixAddress {
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    const native_address: std.c.sockaddr.un = .{ .path = undefined };
    if (path.len >= native_address.path.len) return error.NameTooLong;
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
    if (original.kind != .unix_domain_socket) return error.InvalidEndpoint;

    const socket = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (socket < 0) return error.ProbeFailed;
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
                if (current.kind != .unix_domain_socket or current.inode != original.inode)
                    return error.EndpointChanged;
                try Io.Dir.deleteFileAbsolute(io, path);
                return;
            },
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.ProbeFailed,
        }
    }
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
