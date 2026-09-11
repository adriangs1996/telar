//! Concrete TLS establishment adapter for an authenticated CONNECT exchange.

const GenericTlsTunnelPort = @import("../GenericTlsTunnelPort.zig").Type;
const Establisher = @import("Establisher.zig");
const std = @import("std");
const SessionType = @import("../Session.zig");
const GenericTlsTunnelCommand = @import("../GenericTlsTunnelCommand.zig").Type;
const GenericAttempt = @import("../GenericAttempt.zig").Type;
const tls_transport = @import("../tls.zig");
const GenericEstablished = @import("../GenericEstablished.zig").Type;
const metrics = @import("../metrics.zig");

const port: GenericTlsTunnelPort(Establisher, std.Io.net.Stream, *SessionType) = .{
    .should_intercept = shouldIntercept,
    .record_passthrough = recordPassthrough,
    .intercept = intercept,
    .record_failure = recordFailure,
    .publish_failure = publishFailure,
};

pub const Establish = GenericTlsTunnelCommand(Establisher, port);

fn shouldIntercept(establisher: *Establisher, host: []const u8) bool {
    return establisher.resources.intercept_hosts.contains(host);
}

fn recordPassthrough(establisher: *Establisher) void {
    establisher.resources.telemetry.record(.passthrough_connection);
}

fn intercept(establisher: *Establisher, attempt: GenericAttempt(std.Io.net.Stream)) tls_transport.Error!GenericEstablished(*SessionType) {
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
