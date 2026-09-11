//! Lock-free counters for the asynchronous history path.

const Counters = @import("Counters.zig");
const std = @import("std");

test "queue counters preserve depth high-water and drop semantics" {
    var counters: Counters = .{};

    const first = counters.beginSubmission();
    counters.acceptSubmission(first);
    const second = counters.beginSubmission();
    counters.acceptSubmission(second);
    counters.completeDequeue();
    _ = counters.beginSubmission();
    counters.dropSubmission();

    const current = counters.snapshot(true);

    try std.testing.expectEqual(@as(u64, 1), current.queued);
    try std.testing.expectEqual(@as(u64, 2), current.queue_high_water);
    try std.testing.expectEqual(@as(u64, 1), current.dropped);
    try std.testing.expect(current.available);
}

test "persistence counters retain totals failures and maximum latency" {
    var counters: Counters = .{};

    counters.observeWrite(10, {});
    counters.observeWrite(30, error.WriteFailed);
    counters.observeQuery(20, false);
    counters.observeQuery(40, true);
    counters.recordOpenFailure();

    const current = counters.snapshot(false);

    try std.testing.expectEqual(@as(u64, 2), current.sqlite_writes);
    try std.testing.expectEqual(@as(u64, 1), current.sqlite_write_failures);
    try std.testing.expectEqual(@as(u64, 40), current.sqlite_write_ns);
    try std.testing.expectEqual(@as(u64, 30), current.sqlite_write_max_ns);
    try std.testing.expectEqual(@as(u64, 2), current.sqlite_queries);
    try std.testing.expectEqual(@as(u64, 1), current.sqlite_query_failures);
    try std.testing.expectEqual(@as(u64, 60), current.sqlite_query_ns);
    try std.testing.expectEqual(@as(u64, 40), current.sqlite_query_max_ns);
    try std.testing.expectEqual(@as(u64, 1), current.sqlite_open_failures);
    try std.testing.expect(!current.available);
}
