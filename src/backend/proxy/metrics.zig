//! Lock-free counters owned by the proxy service.

const Counters = @import("Counters.zig");
const std = @import("std");

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
