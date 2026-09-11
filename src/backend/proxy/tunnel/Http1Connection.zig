const Connection = @This();
const source_namespace = @import("http1.zig");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange_support.zig");
const capture = @import("../capture/root.zig");
const provider = @import("../provider/root.zig");
const Options = @import("Http1Options.zig");
io: source_namespace.Io,
transforms: *const middleware.TransformPipeline,
session: *tls.Session,
exchange: *exchange_mod.Exchange,
captures: ?*capture.Producer,
request: provider.RequestObserver = .{},
request_capture: ?*capture.Half = null,
response_capture: ?*capture.Half = null,

/// Binds an intercepted TLS session to its exchange and immutable header
/// transformation pipeline.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: Options) Connection {
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
    source_namespace.RelayConnection.run(connection);
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
    const started_at_ms = source_namespace.Io.Timestamp.now(connection.io, .real).toMilliseconds();
    const base: capture.StartOptions = .{
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
