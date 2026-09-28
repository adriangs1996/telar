//! One connected runtime as a worker hands it to its client: the socket
//! after a successful handshake and, for a remote machine, the SSH session
//! that carries it, whose discovery holds the remote home and login shell.
const localsocket = @import("localsocket");
const std = @import("std");
const Forward = @import("Forward.zig");
const RuntimeConnection = @This();

channel: localsocket.SocketChannel,
forward: ?Forward = null,

/// Closes a connection its client never adopted: the socket, then the SSH
/// session.
///
/// ```zig
/// connection.close(io);
/// ```
pub fn close(self: *RuntimeConnection, io: std.Io) void {
    self.channel.deinit(io);
    if (self.forward) |*forward| {
        forward.stop(io);
    }
}
