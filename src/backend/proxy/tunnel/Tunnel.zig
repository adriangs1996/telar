const core = @import("telar-core");
const Resources = @import("Resources.zig");
const identity = @import("../identity.zig");
const Producer = @import("../capture/Producer.zig");
const std = @import("std");
const Connections = @import("../Connections.zig");
const Resolutions = @import("../Resolutions.zig");
const tunnel_namespace = @import("tunnel_namespace.zig");
const connect_authentication = @import("../connect_authentication.zig");
const Exchange = @import("Exchange.zig");
const Establisher = @import("Establisher.zig");
const H2Connection = @import("H2Connection.zig");
const Http1Connection = @import("Http1Connection.zig");
const Tunnel = @This();

/// The longest CONNECT head: a target and a proxy credential, with room
/// for the headers clients add.
pub const max_connect_head_bytes = 16 * 1024;
pub const connect_head_limit = core.Limit.declare("proxy.max_connect_head_bytes", "bytes", max_connect_head_bytes);

/// How long a refused CONNECT is drained so its answer is not lost to a
/// reset.
const refusal_drain_ms = 200;
/// The answer to a CONNECT head past `max_connect_head_bytes`.
const connect_head_too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

dependencies: Dependencies,
child: std.Io.net.Stream,
/// The connection's row; the tunnel reports its phases there.
slot: Connections.Slot,

/// Creates the per-connection owner without starting network work.
///
/// ```zig
/// var tunnel = Tunnel.init(.{ .dependencies = dependencies, .child = child });
/// ```
pub fn init(options: TunnelOptions) Tunnel {
    return .{
        .dependencies = options.dependencies,
        .child = options.child,
        .slot = options.slot,
    };
}

/// Authenticates one CONNECT request, opens its origin, establishes TLS,
/// and delegates the negotiated protocol until the connection ends. The
/// caller owns the accepted child stream and closes it after the tunnel
/// returns; the tunnel closes its origin stream.
///
/// ```zig
/// try tunnel.run();
/// ```
pub fn run(self: *Tunnel) std.Io.Cancelable!void {
    const path = core.enter(.observation);
    defer path.restore();

    const dependencies = self.dependencies;
    const io = dependencies.tls.io;

    var head: [max_connect_head_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &head);
    const head_len = switch (tunnel_namespace.readConnectHead(io, self.child, &head)) {
        .complete => |len| len,
        .ended => return,
        .too_large => {
            dependencies.tls.telemetry.record(.connect_head_too_large);
            tunnel_namespace.refuse(io, self.child, connect_head_too_large, refusal_drain_ms);
            return;
        },
    };

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
        .connections = dependencies.connections,
        .slot = self.slot,
    };

    exchange.enter(.establishing);

    const upstream = tunnel_namespace.connectUpstream(.{
        .host = target.host,
        .io = io,
        .port = target.port,
        .deadline_ms = exchange.deadline(dependencies.establish_timeout_ms),
        .resolutions = dependencies.resolutions,
        .telemetry = dependencies.tls.telemetry,
    }) catch |err| {
        if (err == error.Timeout) {
            dependencies.tls.telemetry.record(.establish_timeout);
            tunnel_namespace.reply(io, self.child, "HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n");
            return;
        }

        if (err == error.ResolutionLimitReached) {
            dependencies.tls.telemetry.record(.resolution_refusal);
            tunnel_namespace.reply(io, self.child, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
            return;
        }

        dependencies.tls.telemetry.record(.upstream_connect_failure);
        tunnel_namespace.reply(io, self.child, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };

    dependencies.connections.attachOrigin(self.slot, upstream.socket.handle);
    defer {
        dependencies.connections.detachOrigin(self.slot);
        upstream.close(io);
    }

    tunnel_namespace.reply(io, self.child, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var tls_establisher: Establisher = .{ .resources = dependencies.tls };
    const route = tls_establisher.establish(.{
        .host = target.host.bytes,
        .child = self.child,
        .origin = upstream,
    }) orelse return;

    exchange.enter(.open);

    var negotiated_h2 = false;
    const session = switch (route) {
        .passthrough => {
            tunnel_namespace.relayPassthrough(self.child, upstream, &exchange);
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
    slot: Connections.Slot,
};

const Dependencies = struct {
    tls: Resources,
    secret: *const identity.Secret,
    connection_ids: *std.atomic.Value(u64),
    captures: *Producer,
    connections: *Connections,
    /// Where the tunnel's host name resolves.
    resolutions: *Resolutions,
    /// How long the tunnel may take to reach its origin.
    establish_timeout_ms: i64,
};
