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
    /// An HTTP/2 stream relayed without capture: every capture slot was taken.
    h2_capture_stream_skipped,
    /// An HTTP/1.1 head longer than `http1.max_head_bytes`.
    http1_head_too_large,
    /// A chunk-size line longer than `http1.max_chunk_line_bytes`.
    http1_chunk_line_too_long,
    /// A trailer line longer than `http1.max_trailer_line_bytes`.
    http1_trailer_line_too_long,
    /// A CONNECT head longer than `proxy.max_connect_head_bytes`.
    connect_head_too_large,
    /// A connection that sent no complete CONNECT head in time.
    connect_head_timeout,
    /// A connection that did not reach its origin and finish TLS in time.
    establish_timeout,
    /// A connection closed to make room for a new one.
    eviction,
    /// A connection refused because `max_unauthenticated` connections were
    /// still sending their CONNECT head.
    unauthenticated_refusal,
    /// A connection still sending its CONNECT head closed at
    /// `max_unauthenticated` to admit a new one.
    unauthenticated_eviction,
    /// An HTTP/2 header block past `max_header_block_bytes`, which ends
    /// decoding of its direction.
    h2_header_block_too_large,
    /// An HTTP/2 stream the relay could not follow past its tracked streams.
    h2_stream_untracked,
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
        .captures = .{
            .started = 43,
            .truncated = 47,
            .truncated_part = 31,
            .truncated_exchange = 37,
            .truncated_total = 41,
            .skipped = 53,
            .dropped_queue = 59,
            .decode_failed = 61,
            .queued = 67,
            .queue_high_water = 71,
        },
    });

    try std.testing.expectEqual(@as(u32, 23), snapshot.active_connections);
    try std.testing.expectEqual(@as(u64, 29), snapshot.connection_limit_drops);
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
    try std.testing.expectEqual(@as(u64, 11), snapshot.h2_capture_streams_skipped);
    try std.testing.expectEqual(@as(u64, 12), snapshot.http1_heads_too_large);
    try std.testing.expectEqual(@as(u64, 13), snapshot.http1_chunk_lines_too_long);
    try std.testing.expectEqual(@as(u64, 14), snapshot.http1_trailer_lines_too_long);
    try std.testing.expectEqual(@as(u64, 15), snapshot.connect_heads_too_large);
    try std.testing.expectEqual(@as(u64, 16), snapshot.connect_head_timeouts);
    try std.testing.expectEqual(@as(u64, 17), snapshot.establish_timeouts);
    try std.testing.expectEqual(@as(u64, 18), snapshot.evictions);
    try std.testing.expectEqual(@as(u64, 19), snapshot.unauthenticated_refusals);
    try std.testing.expectEqual(@as(u64, 20), snapshot.unauthenticated_evictions);
    try std.testing.expectEqual(@as(u64, 21), snapshot.h2_header_blocks_too_large);
    try std.testing.expectEqual(@as(u64, 22), snapshot.h2_streams_untracked);
    try std.testing.expectEqual(@as(u64, 43), snapshot.capture_started);
    try std.testing.expectEqual(@as(u64, 47), snapshot.capture_truncated);
    try std.testing.expectEqual(@as(u64, 31), snapshot.capture_truncated_part);
    try std.testing.expectEqual(@as(u64, 37), snapshot.capture_truncated_exchange);
    try std.testing.expectEqual(@as(u64, 41), snapshot.capture_truncated_total);
    try std.testing.expectEqual(@as(u64, 53), snapshot.capture_skipped);
    try std.testing.expectEqual(@as(u64, 59), snapshot.capture_dropped_queue);
    try std.testing.expectEqual(@as(u64, 61), snapshot.capture_decode_failed);
    try std.testing.expectEqual(@as(u64, 67), snapshot.queued_captures);
    try std.testing.expectEqual(@as(u64, 71), snapshot.capture_queue_high_water);
}
