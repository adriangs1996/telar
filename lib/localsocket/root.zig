//! Same-user Unix sockets carrying length-prefixed frames: endpoint paths,
//! a listener that admits only peers of the effective uid, the client
//! connect, a connected pair for a child process, allocation-free framing
//! over the stream, and a directory short enough for tests' sockets.

pub const Local = @import("Local.zig");
pub const LocalListener = @import("LocalListener.zig");
pub const SocketChannel = @import("SocketChannel.zig");
pub const SocketDirectory = @import("SocketDirectory.zig");
pub const connect = @import("connect.zig").connect;
pub const pair = @import("pair.zig").pair;
pub const transport = @import("transport.zig");

test {
    _ = @import("Local.zig");
    _ = @import("LocalListener.zig");
    _ = @import("SocketChannel.zig");
    _ = @import("SocketDirectory.zig");
    _ = @import("connect.zig");
    _ = @import("pair.zig");
    _ = @import("endpoint.zig");
    _ = @import("listen.zig");
    _ = @import("transport.zig");
}
