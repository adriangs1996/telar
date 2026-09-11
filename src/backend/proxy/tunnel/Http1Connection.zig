const std = @import("std");
const TransformPipelineType = @import("../TransformPipeline.zig");
const SessionType = @import("../Session.zig");
const ExchangeType = @import("Exchange.zig");
const ProducerType = @import("../capture/Producer.zig");
const Observer = @import("../provider/Observer.zig");
const HalfType = @import("../capture/Half.zig");
const Http1Options = @import("Http1Options.zig");
const http1 = @import("http1.zig");
const StartOptionsType = @import("../capture/StartOptions.zig");
const Connection = @This();

io: std.Io,
transforms: *const TransformPipelineType,
session: *SessionType,
exchange: *ExchangeType,
captures: ?*ProducerType,
request: Observer = .{},
request_capture: ?*HalfType = null,
response_capture: ?*HalfType = null,

/// Binds an intercepted TLS session to its exchange and immutable header
/// transformation pipeline.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: Http1Options) Connection {
    return .{
        .io = options.io,
        .transforms = options.transforms,
        .session = options.session,
        .exchange = options.exchange,
        .captures = options.captures,
    };
}

/// Relays reusable HTTP/1.1 exchanges until close, failure, or upgrade.
/// Provider request and response observers are scrubbed before returning.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(connection: *Connection) void {
    defer connection.request.deinit();
    defer connection.discardCaptures();
    http1.RelayConnection.run(connection);
}

fn discardCaptures(connection: *Connection) void {
    if (connection.request_capture) |half| {
        half.deinit();
        connection.request_capture = null;
    }

    if (connection.response_capture) |half| {
        half.deinit();
        connection.response_capture = null;
    }
}

pub fn beginCapture(connection: *Connection) void {
    connection.discardCaptures();
    const producer = connection.captures orelse return;
    const started_at_ms = std.Io.Timestamp.now(connection.io, .real).toMilliseconds();
    const base: StartOptionsType = .{
        .credential = connection.exchange.credential,
        .dialect = connection.exchange.dialect,
        .protocol = connection.exchange.protocol,
        .key = .{ .connection_id = connection.exchange.connection_id, .stream_id = 0 },
        .side = .request,
        .host = connection.exchange.host.bytes,
        .started_at_ms = started_at_ms,
    };
    connection.request_capture = producer.start(base);
    var response = base;
    response.side = .response;
    connection.response_capture = producer.start(response);
}
