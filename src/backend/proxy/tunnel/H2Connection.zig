const Connection = @This();
const Options = @import("H2Options.zig");
const provider = @import("../provider/root.zig");
const RelayContext = @import("RelayContext.zig");
const source_namespace = @import("h2.zig");
options: Options,

/// Binds an HTTP/2 TLS session to its exchange and immutable transform
/// configuration.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: Options) Connection {
    return .{ .options = options };
}

/// Relays both HTTP/2 directions and owns provider stream observers for
/// the duration of the connection.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(connection: *Connection) void {
    const options = connection.options;
    var responses = provider.ResponseStreams.init(options.gpa, options.exchange.dialect);
    defer responses.deinit();
    var requests = provider.RequestStreams.init(options.exchange.dialect);
    defer requests.deinit();
    var relay: RelayContext = .{
        .io = options.io,
        .transforms = options.transforms,
        .has_custom_transformers = options.has_custom_transformers,
        .session = options.session,
        .exchange = options.exchange,
        .responses = if (options.exchange.dialect == .anthropic_messages) &responses else null,
        .requests = if (options.exchange.dialect == .anthropic_messages) &requests else null,
        .captures = options.captures,
    };

    source_namespace.RelayConnection.run(&relay);
}
