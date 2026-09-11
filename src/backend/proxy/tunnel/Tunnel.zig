const Dependencies = @import("Dependencies.zig");
const std = @import("std");
const TunnelOptions = @import("TunnelOptions.zig");
const enter_module = @import("telar-core").enter;
const head_support = @import("../http/head_support.zig");
const tunnel_namespace = @import("tunnel_namespace.zig");
const ExchangeType = @import("Exchange.zig");
const dialect_module = @import("../provider/dialect.zig");
const EstablisherType = @import("Establisher.zig");
const H2Connection = @import("H2Connection.zig");
const Http1Connection = @import("Http1Connection.zig");
const Tunnel = @This();

dependencies: Dependencies,
child: std.Io.net.Stream,

/// Creates the per-connection owner without starting network work.
///
/// ```zig
/// var tunnel = Tunnel.init(.{ .dependencies = dependencies, .child = child });
/// ```
pub fn init(options: TunnelOptions) Tunnel {
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
pub fn run(tunnel: *Tunnel) std.Io.Cancelable!void {
    const path = enter_module(.observation);
    defer path.restore();

    const dependencies = tunnel.dependencies;
    const io = dependencies.tls.io;
    defer tunnel.child.close(io);

    var head: [head_support.max_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &head);
    const head_len = tunnel_namespace.readConnectHead(io, tunnel.child, &head) orelse return;
    var authenticated = switch (tunnel_namespace.Authenticate.execute(tunnel, head[0..head_len])) {
        .authenticated => |value| value,
        .rejected => |rejection| {
            if (rejection.metric) |metric| {
                tunnel_namespace.recordAuthenticationRejection(dependencies.tls.telemetry, metric);
            }

            tunnel_namespace.reply(io, tunnel.child, rejection.response);
            return;
        },
    };
    defer std.crypto.secureZero(u8, &authenticated.credential.token);

    const target = authenticated.target;
    var exchange: ExchangeType = .{
        .io = io,
        .pipeline = dependencies.pipeline,
        .telemetry = dependencies.tls.telemetry,
        .credential = authenticated.credential,
        .dialect = dialect_module.identify(target.host.bytes),
        .connection_id = dependencies.connection_ids.fetchAdd(1, .monotonic),
        .protocol = .http11,
        .host = target.host,
    };
    defer std.crypto.secureZero(u8, &exchange.credential.token);

    const upstream = tunnel_namespace.connectUpstream(target.host, io, target.port) catch {
        dependencies.tls.telemetry.record(.upstream_connect_failure);
        exchange.publish(.request_failed, 0);
        tunnel_namespace.reply(io, tunnel.child, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer upstream.close(io);
    tunnel_namespace.reply(io, tunnel.child, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var tls_establisher: EstablisherType = .{
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
            tunnel_namespace.relayPassthrough(io, tunnel.child, upstream);
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
        var connection = H2Connection.init(.{
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

    var connection = Http1Connection.init(.{
        .io = io,
        .transforms = dependencies.transforms,
        .session = session,
        .exchange = &exchange,
        .captures = dependencies.captures,
    });
    connection.run();
}
