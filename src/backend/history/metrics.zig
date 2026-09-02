//! Lock-free counters for the asynchronous history path.

const std = @import("std");

pub const Snapshot = struct {
    queued: u64,
    queue_high_water: u64,
    dropped: u64,
    sqlite_writes: u64,
    sqlite_write_failures: u64,
    sqlite_write_ns: u64,
    sqlite_write_max_ns: u64,
    sqlite_queries: u64,
    sqlite_query_failures: u64,
    sqlite_query_ns: u64,
    sqlite_query_max_ns: u64,
    sqlite_open_failures: u64,
    available: bool,
};

pub const Counters = struct {
    queued: std.atomic.Value(u64) = .init(0),
    queue_high_water: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    sqlite_writes: std.atomic.Value(u64) = .init(0),
    sqlite_write_failures: std.atomic.Value(u64) = .init(0),
    sqlite_write_ns: std.atomic.Value(u64) = .init(0),
    sqlite_write_max_ns: std.atomic.Value(u64) = .init(0),
    sqlite_queries: std.atomic.Value(u64) = .init(0),
    sqlite_query_failures: std.atomic.Value(u64) = .init(0),
    sqlite_query_ns: std.atomic.Value(u64) = .init(0),
    sqlite_query_max_ns: std.atomic.Value(u64) = .init(0),
    sqlite_open_failures: std.atomic.Value(u64) = .init(0),

    /// Reserves one logical queue position before a non-blocking submission.
    /// The caller must finish the attempt with `acceptSubmission` or
    /// `dropSubmission`.
    ///
    /// ```zig
    /// const depth = counters.beginSubmission();
    /// counters.acceptSubmission(depth);
    /// ```
    pub fn beginSubmission(counters: *Counters) u64 {
        return counters.queued.fetchAdd(1, .monotonic) + 1;
    }

    /// Commits the high-water mark for an accepted queue submission.
    ///
    /// ```zig
    /// counters.acceptSubmission(depth);
    /// ```
    pub fn acceptSubmission(counters: *Counters, depth: u64) void {
        _ = counters.queue_high_water.fetchMax(depth, .monotonic);
    }

    /// Rolls back a refused queue position and records the dropped request.
    ///
    /// ```zig
    /// counters.dropSubmission();
    /// ```
    pub fn dropSubmission(counters: *Counters) void {
        _ = counters.queued.fetchSub(1, .monotonic);
        _ = counters.dropped.fetchAdd(1, .monotonic);
    }

    /// Releases one queue position after the worker receives its request.
    ///
    /// ```zig
    /// counters.completeDequeue();
    /// ```
    pub fn completeDequeue(counters: *Counters) void {
        _ = counters.queued.fetchSub(1, .monotonic);
    }

    /// Records one SQLite write attempt, including failures and tail latency.
    ///
    /// ```zig
    /// counters.observeWrite(elapsed_ns, result);
    /// ```
    pub fn observeWrite(counters: *Counters, elapsed_ns: u64, result: anyerror!void) void {
        _ = counters.sqlite_writes.fetchAdd(1, .monotonic);
        _ = counters.sqlite_write_ns.fetchAdd(elapsed_ns, .monotonic);
        _ = counters.sqlite_write_max_ns.fetchMax(elapsed_ns, .monotonic);
        result catch {
            _ = counters.sqlite_write_failures.fetchAdd(1, .monotonic);
        };
    }

    /// Records one SQLite query attempt after its response has been built.
    ///
    /// ```zig
    /// counters.observeQuery(elapsed_ns, response == .failed);
    /// ```
    pub fn observeQuery(counters: *Counters, elapsed_ns: u64, failed: bool) void {
        _ = counters.sqlite_queries.fetchAdd(1, .monotonic);
        _ = counters.sqlite_query_ns.fetchAdd(elapsed_ns, .monotonic);
        _ = counters.sqlite_query_max_ns.fetchMax(elapsed_ns, .monotonic);

        if (failed) {
            _ = counters.sqlite_query_failures.fetchAdd(1, .monotonic);
        }
    }

    /// Records that the selected history database could not be opened.
    ///
    /// ```zig
    /// counters.recordOpenFailure();
    /// ```
    pub fn recordOpenFailure(counters: *Counters) void {
        _ = counters.sqlite_open_failures.fetchAdd(1, .monotonic);
    }

    /// Captures one internally consistent-enough telemetry view without locks.
    /// Individual counters remain monotonic while concurrent work continues.
    ///
    /// ```zig
    /// const current = counters.snapshot(store_available);
    /// ```
    pub fn snapshot(counters: *const Counters, available: bool) Snapshot {
        return .{
            .queued = counters.queued.load(.monotonic),
            .queue_high_water = counters.queue_high_water.load(.monotonic),
            .dropped = counters.dropped.load(.monotonic),
            .sqlite_writes = counters.sqlite_writes.load(.monotonic),
            .sqlite_write_failures = counters.sqlite_write_failures.load(.monotonic),
            .sqlite_write_ns = counters.sqlite_write_ns.load(.monotonic),
            .sqlite_write_max_ns = counters.sqlite_write_max_ns.load(.monotonic),
            .sqlite_queries = counters.sqlite_queries.load(.monotonic),
            .sqlite_query_failures = counters.sqlite_query_failures.load(.monotonic),
            .sqlite_query_ns = counters.sqlite_query_ns.load(.monotonic),
            .sqlite_query_max_ns = counters.sqlite_query_max_ns.load(.monotonic),
            .sqlite_open_failures = counters.sqlite_open_failures.load(.monotonic),
            .available = available,
        };
    }
};

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
