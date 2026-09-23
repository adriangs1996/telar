const std = @import("std");
const Snapshot = @import("Snapshot.zig");
const Counters = @This();

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
pub fn beginSubmission(self: *Counters) u64 {
    return self.queued.fetchAdd(1, .monotonic) + 1;
}

/// Commits the high-water mark for an accepted queue submission.
///
/// ```zig
/// counters.acceptSubmission(depth);
/// ```
pub fn acceptSubmission(self: *Counters, depth: u64) void {
    _ = self.queue_high_water.fetchMax(depth, .monotonic);
}

/// Rolls back a refused queue position and records the dropped request.
///
/// ```zig
/// counters.dropSubmission();
/// ```
pub fn dropSubmission(self: *Counters) void {
    _ = self.queued.fetchSub(1, .monotonic);
    _ = self.dropped.fetchAdd(1, .monotonic);
}

/// Releases one queue position after the worker receives its request.
///
/// ```zig
/// counters.completeDequeue();
/// ```
pub fn completeDequeue(self: *Counters) void {
    _ = self.queued.fetchSub(1, .monotonic);
}

/// Records one SQLite write attempt, including failures and tail latency.
///
/// ```zig
/// counters.observeWrite(elapsed_ns, result);
/// ```
pub fn observeWrite(self: *Counters, elapsed_ns: u64, result: anyerror!void) void {
    _ = self.sqlite_writes.fetchAdd(1, .monotonic);
    _ = self.sqlite_write_ns.fetchAdd(elapsed_ns, .monotonic);
    _ = self.sqlite_write_max_ns.fetchMax(elapsed_ns, .monotonic);
    result catch {
        _ = self.sqlite_write_failures.fetchAdd(1, .monotonic);
    };
}

/// Records one SQLite query attempt after its response has been built.
///
/// ```zig
/// counters.observeQuery(elapsed_ns, response == .failed);
/// ```
pub fn observeQuery(self: *Counters, elapsed_ns: u64, failed: bool) void {
    _ = self.sqlite_queries.fetchAdd(1, .monotonic);
    _ = self.sqlite_query_ns.fetchAdd(elapsed_ns, .monotonic);
    _ = self.sqlite_query_max_ns.fetchMax(elapsed_ns, .monotonic);

    if (failed) {
        _ = self.sqlite_query_failures.fetchAdd(1, .monotonic);
    }
}

/// Records that the selected history database could not be opened.
///
/// ```zig
/// counters.recordOpenFailure();
/// ```
pub fn recordOpenFailure(self: *Counters) void {
    _ = self.sqlite_open_failures.fetchAdd(1, .monotonic);
}

/// Captures one internally consistent-enough telemetry view without locks.
/// Individual counters remain monotonic while concurrent work continues.
///
/// ```zig
/// const current = counters.snapshot(store_available);
/// ```
pub fn snapshot(self: *const Counters, available: bool) Snapshot {
    return .{
        .queued = self.queued.load(.monotonic),
        .queue_high_water = self.queue_high_water.load(.monotonic),
        .dropped = self.dropped.load(.monotonic),
        .sqlite_writes = self.sqlite_writes.load(.monotonic),
        .sqlite_write_failures = self.sqlite_write_failures.load(.monotonic),
        .sqlite_write_ns = self.sqlite_write_ns.load(.monotonic),
        .sqlite_write_max_ns = self.sqlite_write_max_ns.load(.monotonic),
        .sqlite_queries = self.sqlite_queries.load(.monotonic),
        .sqlite_query_failures = self.sqlite_query_failures.load(.monotonic),
        .sqlite_query_ns = self.sqlite_query_ns.load(.monotonic),
        .sqlite_query_max_ns = self.sqlite_query_max_ns.load(.monotonic),
        .sqlite_open_failures = self.sqlite_open_failures.load(.monotonic),
        .available = available,
    };
}
