const std = @import("std");
const local = @import("local.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const LocalListener = @This();

listener: std.Io.net.Server,
path: [std.Io.net.UnixAddress.max_len]u8 = undefined,
path_len: usize,
inode: std.Io.File.INode,
active: bool = true,

pub fn listen(io: std.Io, path: []const u8) !LocalListener {
    const address = try local.localAddress(path);
    try local.validateEndpointDirectory(path);
    try local.reclaimStaleEndpoint(io, path);
    var listener = try address.listen(io, .{});
    errdefer listener.deinit(io);

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .unix_domain_socket) {
        return error.InvalidEndpoint;
    }
    errdefer removeIfOwned(io, path, stat.inode);

    // The chmod must go through the path: a Unix socket descriptor does
    // not reference the filesystem node that carries the mode, so fchmod
    // cannot restrict the endpoint. Renaming it out from under us in this
    // window requires write permission on the directory, which the trust
    // validation above already refused to anyone but the owner.
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        path,
        std.Io.File.Permissions.fromMode(0o600),
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

pub fn accept(listener: *LocalListener, io: std.Io) !SocketChannelType {
    std.debug.assert(listener.active);
    const stream = try listener.listener.accept(io);
    errdefer stream.close(io);
    const peer_uid = try local.peerUid(stream.socket.handle);
    if (!local.sameUserPeer(peer_uid, std.c.geteuid())) {
        return error.PeerNotOwned;
    }
    return .init(stream);
}

pub fn deinit(listener: *LocalListener, io: std.Io) void {
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

fn removeIfOwned(io: std.Io, path: []const u8, inode: std.Io.File.INode) void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .unix_domain_socket or stat.inode != inode) {
        return;
    }
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}
