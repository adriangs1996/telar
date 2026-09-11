const Counters = @This();
const std = @import("std");
const source_namespace = @import("metrics.zig");
const LiveState = @import("LiveState.zig");
const Snapshot = @import("Snapshot.zig");
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
claude_inference_requests: std.atomic.Value(u64) = .init(0),
claude_sse_payload_fragments: std.atomic.Value(u64) = .init(0),
claude_turn_completions: std.atomic.Value(u64) = .init(0),
claude_successful_responses: std.atomic.Value(u64) = .init(0),
claude_failure_observations: std.atomic.Value(u64) = .init(0),

/// Records one named proxy outcome without exposing the underlying
/// atomics to protocol adapters.
///
/// ```zig
/// counters.record(.upstream_connect_failure);
/// ```
pub fn record(counters: *Counters, counter: source_namespace.Counter) void {
    const selected = switch (counter) {
        .rejected_connection => &counters.rejected_connections,
        .invalid_authorization_rejection => &counters.invalid_authorization_rejections,
        .unknown_credential_rejection => &counters.unknown_credential_rejections,
        .h2_decode_failure => &counters.h2_decode_failures,
        .passthrough_connection => &counters.passthrough_connections,
        .upstream_connect_failure => &counters.upstream_connect_failures,
        .tls_context_failure => &counters.tls_context_failures,
        .tls_upstream_handshake_failure => &counters.tls_upstream_handshake_failures,
        .tls_downstream_handshake_failure => &counters.tls_downstream_handshake_failures,
        .tls_mint_failure => &counters.tls_mint_failures,
        .claude_inference_request => &counters.claude_inference_requests,
        .claude_sse_payload_fragment => &counters.claude_sse_payload_fragments,
        .claude_turn_completion => &counters.claude_turn_completions,
        .claude_successful_response => &counters.claude_successful_responses,
        .claude_failure_observation => &counters.claude_failure_observations,
    };

    _ = selected.fetchAdd(1, .monotonic);
}

/// Combines owned counters with current queue and admission state.
///
/// ```zig
/// const snapshot = counters.snapshot(live_state);
/// ```
pub fn snapshot(counters: *const Counters, live: LiveState) Snapshot {
    return .{
        .active_connections = live.connections.active,
        .queued_events = live.observations.queued,
        .event_queue_high_water = live.observations.high_water,
        .dropped_events = live.observations.dropped,
        .rejected_connections = counters.rejected_connections.load(.monotonic),
        .invalid_authorization_rejections = counters.invalid_authorization_rejections.load(.monotonic),
        .unknown_credential_rejections = counters.unknown_credential_rejections.load(.monotonic),
        .connection_limit_drops = live.connections.limit_drops,
        .h2_decode_failures = counters.h2_decode_failures.load(.monotonic),
        .passthrough_connections = counters.passthrough_connections.load(.monotonic),
        .upstream_connect_failures = counters.upstream_connect_failures.load(.monotonic),
        .tls_context_failures = counters.tls_context_failures.load(.monotonic),
        .tls_upstream_handshake_failures = counters.tls_upstream_handshake_failures.load(.monotonic),
        .tls_downstream_handshake_failures = counters.tls_downstream_handshake_failures.load(.monotonic),
        .tls_mint_failures = counters.tls_mint_failures.load(.monotonic),
        .claude_inference_requests = counters.claude_inference_requests.load(.monotonic),
        .claude_sse_payload_fragments = counters.claude_sse_payload_fragments.load(.monotonic),
        .claude_turn_completions = counters.claude_turn_completions.load(.monotonic),
        .claude_successful_responses = counters.claude_successful_responses.load(.monotonic),
        .claude_failure_observations = counters.claude_failure_observations.load(.monotonic),
        .capture_started = live.captures.started,
        .capture_truncated = live.captures.truncated,
        .capture_skipped_quota = live.captures.skipped_quota,
        .capture_dropped_queue = live.captures.dropped_queue,
        .capture_decode_failed = live.captures.decode_failed,
        .queued_captures = live.captures.queued,
        .capture_queue_high_water = live.captures.queue_high_water,
    };
}
