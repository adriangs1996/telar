//! One connected runtime as a worker hands it to its client: the socket
//! after a successful handshake and, for a remote machine, the SSH forward
//! that carries it, whose discovery holds the remote home and login shell.
const localsocket = @import("localsocket");
const Forward = @import("Forward.zig");
const RuntimeConnection = @This();

channel: localsocket.SocketChannel,
forward: ?Forward = null,
