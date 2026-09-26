const std = @import("std");
const metrics = @import("metrics.zig");
const SlotSnapshot = @import("SlotSnapshot.zig");
const CaptureMetrics = @import("capture/CaptureMetrics.zig");
const Snapshot = @import("Snapshot.zig");
const Counters = @This();

rejected_connections: std.atomic.Value(u64) = .init(0),
invalid_authorization_rejections: std.atomic.Value(u64) = .init(0),
unknown_credential_rejections: std.atomic.Value(u64) = .init(0),
h2_decode_failures: std.atomic.Value(u64) = .init(0),
passthrough_connections: std.atomic.Value(u64) = .init(0),
upstream_connect_failures: std.atomic.Value(u64) = .init(0),
tls_context_failures: std.atomic.Value(u64) = .init(0),
tls_upstream_handshake_failures: std.atomic.Value(u64) = .init(0),
tls_downstream_handshake_failures: std.atomic.Value(u64) = .init(0),
tls_mint_failures: std.atomic.Value(u64) = .init(0),

/// Records one named proxy outcome without exposing the underlying
/// atomics to protocol adapters.
///
/// ```zig
/// counters.record(.upstream_connect_failure);
/// ```
pub fn record(self: *Counters, counter: metrics.Counter) void {
    const selected = switch (counter) {
        .rejected_connection => &self.rejected_connections,
        .invalid_authorization_rejection => &self.invalid_authorization_rejections,
        .unknown_credential_rejection => &self.unknown_credential_rejections,
        .h2_decode_failure => &self.h2_decode_failures,
        .passthrough_connection => &self.passthrough_connections,
        .upstream_connect_failure => &self.upstream_connect_failures,
        .tls_context_failure => &self.tls_context_failures,
        .tls_upstream_handshake_failure => &self.tls_upstream_handshake_failures,
        .tls_downstream_handshake_failure => &self.tls_downstream_handshake_failures,
        .tls_mint_failure => &self.tls_mint_failures,
    };

    _ = selected.fetchAdd(1, .monotonic);
}

/// Combines owned counters with current admission and capture state.
///
/// ```zig
/// const snapshot = counters.snapshot(live_state);
/// ```
pub fn snapshot(self: *const Counters, live: LiveState) Snapshot {
    return .{
        .active_connections = live.connections.active,
        .rejected_connections = self.rejected_connections.load(.monotonic),
        .invalid_authorization_rejections = self.invalid_authorization_rejections.load(.monotonic),
        .unknown_credential_rejections = self.unknown_credential_rejections.load(.monotonic),
        .connection_limit_drops = live.connections.limit_drops,
        .h2_decode_failures = self.h2_decode_failures.load(.monotonic),
        .passthrough_connections = self.passthrough_connections.load(.monotonic),
        .upstream_connect_failures = self.upstream_connect_failures.load(.monotonic),
        .tls_context_failures = self.tls_context_failures.load(.monotonic),
        .tls_upstream_handshake_failures = self.tls_upstream_handshake_failures.load(.monotonic),
        .tls_downstream_handshake_failures = self.tls_downstream_handshake_failures.load(.monotonic),
        .tls_mint_failures = self.tls_mint_failures.load(.monotonic),
        .capture_started = live.captures.started,
        .capture_truncated = live.captures.truncated,
        .capture_skipped_quota = live.captures.skipped_quota,
        .capture_dropped_queue = live.captures.dropped_queue,
        .capture_decode_failed = live.captures.decode_failed,
        .queued_captures = live.captures.queued,
        .capture_queue_high_water = live.captures.queue_high_water,
    };
}

const LiveState = struct {
    connections: SlotSnapshot,
    captures: CaptureMetrics = .{},
};
