//! Lock-free counters owned by the proxy service.

const std = @import("std");
const connection_admission = @import("connection_admission.zig");
const capture = @import("capture/root.zig");
const observation_queue = @import("observation_queue.zig");

pub const Counter = enum {
    rejected_connection,
    invalid_authorization_rejection,
    unknown_credential_rejection,
    h2_decode_failure,
    passthrough_connection,
    upstream_connect_failure,
    tls_context_failure,
    tls_upstream_handshake_failure,
    tls_downstream_handshake_failure,
    tls_mint_failure,
    claude_inference_request,
    claude_sse_payload_fragment,
    claude_turn_completion,
    claude_successful_response,
    claude_failure_observation,
};

pub const LiveState = struct {
    connections: connection_admission.SlotSnapshot,
    observations: observation_queue.Metrics,
    captures: capture.Metrics = .{},
};

pub const Snapshot = struct {
    active_connections: u32 = 0,
    queued_events: u64 = 0,
    event_queue_high_water: u64 = 0,
    dropped_events: u64 = 0,
    rejected_connections: u64 = 0,
    invalid_authorization_rejections: u64 = 0,
    unknown_credential_rejections: u64 = 0,
    connection_limit_drops: u64 = 0,
    h2_decode_failures: u64 = 0,
    passthrough_connections: u64 = 0,
    upstream_connect_failures: u64 = 0,
    tls_context_failures: u64 = 0,
    tls_upstream_handshake_failures: u64 = 0,
    tls_downstream_handshake_failures: u64 = 0,
    tls_mint_failures: u64 = 0,
    claude_inference_requests: u64 = 0,
    claude_sse_payload_fragments: u64 = 0,
    claude_turn_completions: u64 = 0,
    claude_successful_responses: u64 = 0,
    claude_failure_observations: u64 = 0,
    capture_started: u64 = 0,
    capture_truncated: u64 = 0,
    capture_skipped_quota: u64 = 0,
    capture_dropped_queue: u64 = 0,
    capture_decode_failed: u64 = 0,
    queued_captures: u64 = 0,
    capture_queue_high_water: u64 = 0,
};

pub const Counters = struct {
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
    pub fn record(counters: *Counters, counter: Counter) void {
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
};

test "each proxy counter has one independent snapshot field" {
    var counters: Counters = .{};

    for (std.enums.values(Counter), 1..) |counter, count| {
        for (0..count) |_| {
            counters.record(counter);
        }
    }

    const snapshot = counters.snapshot(.{
        .connections = .{ .active = 23, .limit_drops = 29 },
        .observations = .{ .queued = 31, .high_water = 37, .dropped = 41 },
        .captures = .{
            .started = 43,
            .truncated = 47,
            .skipped_quota = 53,
            .dropped_queue = 59,
            .decode_failed = 61,
            .queued = 67,
            .queue_high_water = 71,
        },
    });

    try std.testing.expectEqual(@as(u32, 23), snapshot.active_connections);
    try std.testing.expectEqual(@as(u64, 29), snapshot.connection_limit_drops);
    try std.testing.expectEqual(@as(u64, 31), snapshot.queued_events);
    try std.testing.expectEqual(@as(u64, 37), snapshot.event_queue_high_water);
    try std.testing.expectEqual(@as(u64, 41), snapshot.dropped_events);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 2), snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 3), snapshot.unknown_credential_rejections);
    try std.testing.expectEqual(@as(u64, 4), snapshot.h2_decode_failures);
    try std.testing.expectEqual(@as(u64, 5), snapshot.passthrough_connections);
    try std.testing.expectEqual(@as(u64, 6), snapshot.upstream_connect_failures);
    try std.testing.expectEqual(@as(u64, 7), snapshot.tls_context_failures);
    try std.testing.expectEqual(@as(u64, 8), snapshot.tls_upstream_handshake_failures);
    try std.testing.expectEqual(@as(u64, 9), snapshot.tls_downstream_handshake_failures);
    try std.testing.expectEqual(@as(u64, 10), snapshot.tls_mint_failures);
    try std.testing.expectEqual(@as(u64, 11), snapshot.claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 12), snapshot.claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 13), snapshot.claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 14), snapshot.claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 15), snapshot.claude_failure_observations);
    try std.testing.expectEqual(@as(u64, 43), snapshot.capture_started);
    try std.testing.expectEqual(@as(u64, 47), snapshot.capture_truncated);
    try std.testing.expectEqual(@as(u64, 53), snapshot.capture_skipped_quota);
    try std.testing.expectEqual(@as(u64, 59), snapshot.capture_dropped_queue);
    try std.testing.expectEqual(@as(u64, 61), snapshot.capture_decode_failed);
    try std.testing.expectEqual(@as(u64, 67), snapshot.queued_captures);
    try std.testing.expectEqual(@as(u64, 71), snapshot.capture_queue_high_water);
}
