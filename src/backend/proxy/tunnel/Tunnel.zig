const httprelay = @import("httprelay");
const core = @import("telar-core");
const Resources = @import("Resources.zig");
const identity = @import("../identity.zig");
const Producer = @import("../capture/Producer.zig");
const std = @import("std");
const http1 = httprelay.http1;
const tunnel_namespace = @import("tunnel_namespace.zig");
const connect_authentication = @import("../connect_authentication.zig");
const Exchange = @import("Exchange.zig");
const Establisher = @import("Establisher.zig");
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
pub fn run(self: *Tunnel) std.Io.Cancelable!void {
    const path = core.enter(.observation);
    defer path.restore();

    const dependencies = self.dependencies;
    const io = dependencies.tls.io;
    defer self.child.close(io);

    var head: [http1.max_head_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &head);
    const head_len = tunnel_namespace.readConnectHead(io, self.child, &head) orelse return;
    const target = switch (connect_authentication.authenticate(dependencies.secret, head[0..head_len])) {
        .authenticated => |value| value,
        .rejected => |rejection| {
            if (rejection.metric) |metric| {
                tunnel_namespace.recordAuthenticationRejection(dependencies.tls.telemetry, metric);
            }

            tunnel_namespace.reply(io, self.child, rejection.response);
            return;
        },
    };

    var exchange: Exchange = .{
        .io = io,
        .telemetry = dependencies.tls.telemetry,
        .connection_id = dependencies.connection_ids.fetchAdd(1, .monotonic),
        .protocol = .http11,
        .host = target.host,
    };

    const upstream = tunnel_namespace.connectUpstream(target.host, io, target.port) catch {
        dependencies.tls.telemetry.record(.upstream_connect_failure);
        tunnel_namespace.reply(io, self.child, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer upstream.close(io);
    tunnel_namespace.reply(io, self.child, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var tls_establisher: Establisher = .{ .resources = dependencies.tls };
    const route = tls_establisher.establish(.{
        .host = target.host.bytes,
        .child = self.child,
        .origin = upstream,
    }) orelse return;

    var negotiated_h2 = false;
    const session = switch (route) {
        .passthrough => {
            tunnel_namespace.relayPassthrough(io, self.child, upstream);
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
            .session = session,
            .exchange = &exchange,
            .captures = dependencies.captures,
        });

        connection.run();
        return;
    }

    var connection = Http1Connection.init(.{
        .io = io,
        .session = session,
        .exchange = &exchange,
        .captures = dependencies.captures,
    });
    connection.run();
}

const TunnelOptions = struct {
    dependencies: Dependencies,
    child: std.Io.net.Stream,
};

const Dependencies = struct {
    tls: Resources,
    secret: *const identity.Secret,
    connection_ids: *std.atomic.Value(u64),
    captures: *Producer,
};
