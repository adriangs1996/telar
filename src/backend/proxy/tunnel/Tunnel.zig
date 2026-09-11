const Tunnel = @This();
const Dependencies = @import("Dependencies.zig");
const source_namespace = @import("root.zig");
const Options = @import("TunnelOptions.zig");
const http = @import("../http/root.zig");
const std = @import("std");
const exchange_mod = @import("exchange_support.zig");
const provider = @import("../provider/root.zig");
const tls_adapter = @import("tls.zig");
const h2_adapter = @import("h2.zig");
const http1_adapter = @import("http1.zig");
dependencies: Dependencies,
child: source_namespace.net.Stream,

/// Creates the per-connection owner without starting network work.
///
/// ```zig
/// var tunnel = Tunnel.init(.{ .dependencies = dependencies, .child = child });
/// ```
pub fn init(options: Options) Tunnel {
    return .{
        .dependencies = options.dependencies,
        .child = options.child,
    };
}

/// Authenticates one CONNECT request, opens its origin, establishes TLS,
/// and delegates the negotiated protocol until the connection ends.
/// The tunnel always closes its accepted child stream before returning.
///
/// ```zig
/// try tunnel.run();
/// ```
pub fn run(tunnel: *Tunnel) source_namespace.Io.Cancelable!void {
    const path = source_namespace.diagnostics.enter(.observation);
    defer path.restore();

    const dependencies = tunnel.dependencies;
    const io = dependencies.tls.io;
    defer tunnel.child.close(io);

    var head: [http.max_head_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &head);
    const head_len = source_namespace.readConnectHead(io, tunnel.child, &head) orelse return;
    var authenticated = switch (source_namespace.Authenticate.execute(tunnel, head[0..head_len])) {
        .authenticated => |value| value,
        .rejected => |rejection| {
            if (rejection.metric) |metric| {
                source_namespace.recordAuthenticationRejection(dependencies.tls.telemetry, metric);
            }

            source_namespace.reply(io, tunnel.child, rejection.response);
            return;
        },
    };
    defer std.crypto.secureZero(u8, &authenticated.credential.token);

    const target = authenticated.target;
    var exchange: exchange_mod.Exchange = .{
        .io = io,
        .pipeline = dependencies.pipeline,
        .telemetry = dependencies.tls.telemetry,
        .credential = authenticated.credential,
        .dialect = provider.identify(target.host.bytes),
        .connection_id = dependencies.connection_ids.fetchAdd(1, .monotonic),
        .protocol = .http11,
        .host = target.host,
    };
    defer std.crypto.secureZero(u8, &exchange.credential.token);

    const upstream = source_namespace.connectUpstream(target.host, io, target.port) catch {
        dependencies.tls.telemetry.record(.upstream_connect_failure);
        exchange.publish(.request_failed, 0);
        source_namespace.reply(io, tunnel.child, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer upstream.close(io);
    source_namespace.reply(io, tunnel.child, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var tls_establisher: tls_adapter.Establisher = .{
        .resources = dependencies.tls,
        .exchange = &exchange,
    };
    const route = tls_establisher.establish(.{
        .host = target.host.bytes,
        .child = tunnel.child,
        .origin = upstream,
    }) orelse return;

    var negotiated_h2 = false;
    const session = switch (route) {
        .passthrough => {
            source_namespace.relayPassthrough(io, tunnel.child, upstream);
            return;
        },
        .http11 => |established| established,
        .h2 => |established| block: {
            negotiated_h2 = true;
            break :block established;
        },
    };
    defer session.deinit();

    exchange.protocol = if (negotiated_h2) .h2 else .http11;
    if (negotiated_h2) {
        var connection = h2_adapter.Connection.init(.{
            .io = io,
            .gpa = dependencies.tls.gpa,
            .transforms = dependencies.transforms,
            .has_custom_transformers = dependencies.has_custom_transformers,
            .session = session,
            .exchange = &exchange,
            .captures = dependencies.captures,
        });

        connection.run();
        return;
    }

    var connection = http1_adapter.Connection.init(.{
        .io = io,
        .transforms = dependencies.transforms,
        .session = session,
        .exchange = &exchange,
        .captures = dependencies.captures,
    });
    connection.run();
}
