//! Concrete TLS establishment adapter for an authenticated CONNECT exchange.

const std = @import("std");
const ca = @import("../ca.zig");
const metrics = @import("../metrics.zig");
const interception_policy = @import("../interception_policy.zig");
const tls_transport = @import("../tls.zig");
const tls_tunnel = @import("../tls_tunnel.zig");
const exchange_mod = @import("exchange.zig");

const Io = std.Io;
const net = Io.net;

pub const Resources = struct {
    io: Io,
    gpa: std.mem.Allocator,
    authority: *ca.Authority,
    roots: *tls_transport.Roots,
    intercept_hosts: *const interception_policy.Policy,
    telemetry: *metrics.Counters,
};

pub const Establisher = struct {
    resources: Resources,
    exchange: *exchange_mod.Exchange,

    /// Applies the interception allowlist or establishes an opaque tunnel.
    /// Interception failures record their exact stage and publish one failed
    /// exchange.
    ///
    /// ```zig
    /// const route = establisher.establish(.{
    ///     .host = host,
    ///     .child = child,
    ///     .origin = origin,
    /// });
    /// ```
    pub fn establish(establisher: *Establisher, attempt: tls_tunnel.Attempt(net.Stream)) ?tls_tunnel.Route(*tls_transport.Session) {
        return Establish.execute(establisher, attempt);
    }
};

const port: tls_tunnel.Port(Establisher, net.Stream, *tls_transport.Session) = .{
    .should_intercept = shouldIntercept,
    .record_passthrough = recordPassthrough,
    .intercept = intercept,
    .record_failure = recordFailure,
    .publish_failure = publishFailure,
};

const Establish = tls_tunnel.Command(Establisher, port);

fn shouldIntercept(establisher: *Establisher, host: []const u8) bool {
    return establisher.resources.intercept_hosts.contains(host);
}

fn recordPassthrough(establisher: *Establisher) void {
    establisher.resources.telemetry.record(.passthrough_connection);
}

fn intercept(establisher: *Establisher, attempt: tls_tunnel.Attempt(net.Stream)) tls_transport.Error!tls_tunnel.Established(*tls_transport.Session) {
    const resources = establisher.resources;
    const session = try tls_transport.intercept(.{
        .io = resources.io,
        .gpa = resources.gpa,
        .authority = resources.authority,
        .roots = resources.roots,
        .host = attempt.host,
        .child = attempt.child,
        .origin = attempt.origin,
    });

    return .{ .session = session, .protocol = session.negotiated() };
}

fn recordFailure(establisher: *Establisher, failure: tls_transport.Error) void {
    establisher.resources.telemetry.record(failureCounter(failure));
}

fn publishFailure(establisher: *Establisher) void {
    establisher.exchange.publish(.request_failed, 0);
}

fn failureCounter(failure: tls_transport.Error) metrics.Counter {
    return switch (failure) {
        error.ContextFailed => .tls_context_failure,
        error.UpstreamHandshakeFailed => .tls_upstream_handshake_failure,
        error.DownstreamHandshakeFailed => .tls_downstream_handshake_failure,
        error.MintFailed => .tls_mint_failure,
    };
}

test "each TLS establishment failure maps to its exact counter" {
    try std.testing.expectEqual(metrics.Counter.tls_context_failure, failureCounter(error.ContextFailed));
    try std.testing.expectEqual(metrics.Counter.tls_upstream_handshake_failure, failureCounter(error.UpstreamHandshakeFailed));
    try std.testing.expectEqual(metrics.Counter.tls_downstream_handshake_failure, failureCounter(error.DownstreamHandshakeFailed));
    try std.testing.expectEqual(metrics.Counter.tls_mint_failure, failureCounter(error.MintFailed));
}
