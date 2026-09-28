const Resources = @import("Resources.zig");
const std = @import("std");
const localca = @import("localca");
const metrics = @import("../metrics.zig");
const Session = localca.Session;
const tls = localca.tls;
const Establisher = @This();

resources: Resources,

/// Passes every host through unless the interception allowlist names it. A
/// successful interception transfers session ownership through an explicit
/// HTTP/1.1 or HTTP/2 route. Every TLS failure records its exact stage and
/// returns null.
///
/// ```zig
/// const route = establisher.establish(.{
///     .host = host,
///     .child = child,
///     .origin = origin,
/// });
/// ```
pub fn establish(self: *Establisher, attempt: Attempt) ?Route {
    if (!self.resources.intercept_hosts.contains(attempt.host)) {
        self.resources.telemetry.record(.passthrough_connection);
        return .passthrough;
    }

    const session = tls.intercept(.{
        .io = self.resources.io,
        .gpa = self.resources.gpa,
        .authority = self.resources.authority,
        .roots = self.resources.roots,
        .host = attempt.host,
        .child = attempt.child,
        .origin = attempt.origin,
    }) catch |failure| {
        self.resources.telemetry.record(failureCounter(failure));
        return null;
    };

    return switch (session.negotiated()) {
        .http11 => .{ .http11 = session },
        .h2 => .{ .h2 = session },
    };
}

fn failureCounter(failure: tls.Error) metrics.Counter {
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

/// One authenticated tunnel before policy decides whether to intercept it.
const Attempt = struct {
    host: []const u8,
    child: std.Io.net.Stream,
    origin: std.Io.net.Stream,
};

/// How the tunnel continues: opaque bytes, or an intercepted session.
const Route = union(enum) {
    passthrough,
    http11: *Session,
    h2: *Session,
};
