const std = @import("std");
const TransformPipeline = @import("../TransformPipeline.zig");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const Observer = @import("../provider/Observer.zig");
const Half = @import("../capture/Half.zig");
const http1 = @import("http1.zig");
const StartOptions = @import("../capture/StartOptions.zig");
const Connection = @This();

io: std.Io,
transforms: *const TransformPipeline,
session: *Session,
exchange: *Exchange,
captures: ?*Producer,
request: Observer = .{},
request_capture: ?*Half = null,
response_capture: ?*Half = null,

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
pub fn run(self: *Connection) void {
    defer self.request.deinit();
    defer self.discardCaptures();
    http1.RelayConnection.run(self);
}

fn discardCaptures(self: *Connection) void {
    if (self.request_capture) |half| {
        half.deinit();
        self.request_capture = null;
    }

    if (self.response_capture) |half| {
        half.deinit();
        self.response_capture = null;
    }
}

pub fn beginCapture(self: *Connection) void {
    self.discardCaptures();
    const producer = self.captures orelse return;
    const started_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    const base: StartOptions = .{
        .credential = self.exchange.credential,
        .dialect = self.exchange.dialect,
        .protocol = self.exchange.protocol,
        .key = .{ .connection_id = self.exchange.connection_id, .stream_id = 0 },
        .side = .request,
        .host = self.exchange.host.bytes,
        .started_at_ms = started_at_ms,
    };
    self.request_capture = producer.start(base);
    var response = base;
    response.side = .response;
    self.response_capture = producer.start(response);
}

const Http1Options = struct {
    io: std.Io,
    transforms: *const TransformPipeline,
    session: *Session,
    exchange: *Exchange,
    captures: ?*Producer = null,
};
