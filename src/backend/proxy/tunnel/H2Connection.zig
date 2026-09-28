const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const RelayContext = @import("RelayContext.zig");
const Connection = @This();

options: H2Options,

/// Binds an HTTP/2 TLS session to its exchange.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: H2Options) Connection {
    return .{ .options = options };
}

/// Relays both HTTP/2 directions for the duration of the connection.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(self: *Connection) void {
    const options = self.options;
    var relay: RelayContext = .{
        .io = options.io,
        .session = options.session,
        .exchange = options.exchange,
        .captures = options.captures,
    };

    relay.run();
}

const H2Options = struct {
    io: std.Io,
    session: *Session,
    exchange: *Exchange,
    captures: ?*Producer = null,
};
