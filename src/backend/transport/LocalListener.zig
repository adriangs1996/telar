const LocalListener = @This();
const source_namespace = @import("local.zig");
const std = @import("std");
const core = @import("telar-core");
listener: source_namespace.Io.net.Server,
path: [source_namespace.Io.net.UnixAddress.max_len]u8 = undefined,
path_len: usize,
inode: source_namespace.Io.File.INode,
active: bool = true,

pub fn listen(io: source_namespace.Io, path: []const u8) !LocalListener {
    const address = try source_namespace.localAddress(path);
    try source_namespace.validateEndpointDirectory(path);
    try source_namespace.reclaimStaleEndpoint(io, path);
    var listener = try address.listen(io, .{});
    errdefer listener.deinit(io);

    const stat = try source_namespace.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .unix_domain_socket) {
        return error.InvalidEndpoint;
    }
    errdefer removeIfOwned(io, path, stat.inode);

    // The chmod must go through the path: a Unix socket descriptor does
    // not reference the filesystem node that carries the mode, so fchmod
    // cannot restrict the endpoint. Renaming it out from under us in this
    // window requires write permission on the directory, which the trust
    // validation above already refused to anyone but the owner.
    try source_namespace.Io.Dir.cwd().setFilePermissions(
        io,
        path,
        source_namespace.Io.File.Permissions.fromMode(0o600),
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

pub fn accept(listener: *LocalListener, io: source_namespace.Io) !core.transport.SocketChannel {
    std.debug.assert(listener.active);
    const stream = try listener.listener.accept(io);
    errdefer stream.close(io);
    const peer_uid = try source_namespace.peerUid(stream.socket.handle);
    if (!source_namespace.sameUserPeer(peer_uid, std.c.geteuid())) {
        return error.PeerNotOwned;
    }
    return .init(stream);
}

pub fn deinit(listener: *LocalListener, io: source_namespace.Io) void {
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

fn removeIfOwned(io: source_namespace.Io, path: []const u8, inode: source_namespace.Io.File.INode) void {
    const stat = source_namespace.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .unix_domain_socket or stat.inode != inode) {
        return;
    }
    source_namespace.Io.Dir.deleteFileAbsolute(io, path) catch {};
}
