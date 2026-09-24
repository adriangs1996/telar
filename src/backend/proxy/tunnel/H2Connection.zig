const httprelay = @import("httprelay");
const std = @import("std");
const Rewrite = httprelay.Rewrite;
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const RelayContext = @import("RelayContext.zig");
const Connection = @This();

options: H2Options,

/// Binds an HTTP/2 TLS session to its exchange and the rewrites its request
/// heads receive.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: H2Options) Connection {
    return .{ .options = options };
}

/// Relays both HTTP/2 directions and owns provider stream observers for
/// the duration of the connection.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(self: *Connection) void {
    const options = self.options;
    var responses = ResponseStreams.init(options.gpa, options.exchange.dialect);
    defer responses.deinit();
    var requests = Streams.init(options.exchange.dialect);
    defer requests.deinit();
    var relay: RelayContext = .{
        .io = options.io,
        .request_rewrites = options.request_rewrites,
        .session = options.session,
        .exchange = options.exchange,
        .responses = if (options.exchange.dialect == .anthropic_messages) &responses else null,
        .requests = if (options.exchange.dialect == .anthropic_messages) &requests else null,
        .captures = options.captures,
    };

    relay.run();
}

const H2Options = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    request_rewrites: []const Rewrite,
    session: *Session,
    exchange: *Exchange,
    captures: ?*Producer = null,
};
