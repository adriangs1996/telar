const std = @import("std");
const metrics = @import("metrics.zig");
const SlotSnapshot = @import("SlotSnapshot.zig");
const CaptureMetrics = @import("capture/CaptureMetrics.zig");
const Snapshot = @import("Snapshot.zig");
const Counters = @This();

/// One lock-free count per named proxy outcome.
values: std.EnumArray(metrics.Counter, std.atomic.Value(u64)) = .initFill(.init(0)),

/// Records one named proxy outcome without exposing the underlying
/// atomics to protocol adapters.
///
/// ```zig
/// counters.record(.upstream_connect_failure);
/// ```
pub fn record(self: *Counters, counter: metrics.Counter) void {
    _ = self.values.getPtr(counter).fetchAdd(1, .monotonic);
}

/// Combines owned counters with current admission and capture state.
///
/// ```zig
/// const snapshot = counters.snapshot(live_state);
/// ```
pub fn snapshot(self: *const Counters, live: LiveState) Snapshot {
    return .{
        .active_connections = live.connections.active,
        .rejected_connections = self.load(.rejected_connection),
        .invalid_authorization_rejections = self.load(.invalid_authorization_rejection),
        .unknown_credential_rejections = self.load(.unknown_credential_rejection),
        .connection_limit_drops = live.connections.limit_drops,
        .h2_decode_failures = self.load(.h2_decode_failure),
        .passthrough_connections = self.load(.passthrough_connection),
        .upstream_connect_failures = self.load(.upstream_connect_failure),
        .tls_context_failures = self.load(.tls_context_failure),
        .tls_upstream_handshake_failures = self.load(.tls_upstream_handshake_failure),
        .tls_downstream_handshake_failures = self.load(.tls_downstream_handshake_failure),
        .tls_mint_failures = self.load(.tls_mint_failure),
        .h2_capture_streams_skipped = self.load(.h2_capture_stream_skipped),
        .http1_heads_too_large = self.load(.http1_head_too_large),
        .http1_chunk_lines_too_long = self.load(.http1_chunk_line_too_long),
        .http1_trailer_lines_too_long = self.load(.http1_trailer_line_too_long),
        .connect_heads_too_large = self.load(.connect_head_too_large),
        .connect_head_timeouts = self.load(.connect_head_timeout),
        .establish_timeouts = self.load(.establish_timeout),
        .evictions = self.load(.eviction),
        .unauthenticated_refusals = self.load(.unauthenticated_refusal),
        .unauthenticated_evictions = self.load(.unauthenticated_eviction),
        .h2_header_blocks_too_large = self.load(.h2_header_block_too_large),
        .h2_streams_untracked = self.load(.h2_stream_untracked),
        .resolution_refusals = self.load(.resolution_refusal),
        .resolutions_truncated = self.load(.resolution_truncated),
        .capture_started = live.captures.started,
        .capture_truncated = live.captures.truncated,
        .capture_truncated_part = live.captures.truncated_part,
        .capture_truncated_exchange = live.captures.truncated_exchange,
        .capture_truncated_total = live.captures.truncated_total,
        .capture_skipped = live.captures.skipped,
        .capture_dropped_queue = live.captures.dropped_queue,
        .capture_decode_failed = live.captures.decode_failed,
        .queued_captures = live.captures.queued,
        .capture_queue_high_water = live.captures.queue_high_water,
    };
}

fn load(self: *const Counters, counter: metrics.Counter) u64 {
    return self.values.getPtrConst(counter).load(.monotonic);
}

const LiveState = struct {
    connections: SlotSnapshot,
    captures: CaptureMetrics = .{},
};
