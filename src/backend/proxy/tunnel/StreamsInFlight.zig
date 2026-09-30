//! The HTTP/2 streams of one connection that count as exchanges in flight.
//! Both relay directions report stream stages, and one stream can end more
//! than once on the wire: END_STREAM then RST_STREAM, or a reset from each
//! side. Only a stream this table saw start counts, and only its first end
//! stops counting, so a spurious end never takes the protection from
//! another stream.
const h2frames = @import("h2frames");
const std = @import("std");
const StreamsInFlight = @This();

/// Streams followed at once: every stream the relay tracks, twice, since a
/// response may outlive its request's slot in the tracker. A stream past
/// this is relayed without counting.
const capacity = 2 * h2frames.streams.max_tracked_streams;

ids: [capacity]u32 = @splat(0),
guard: std.atomic.Mutex = .unlocked,

/// Records `stream_id` starting and returns whether it now counts.
///
/// ```zig
/// if (streams.start(stream_id)) exchange.beginExchange();
/// ```
pub fn start(self: *StreamsInFlight, stream_id: u32) bool {
    if (stream_id == 0) {
        return false;
    }

    self.lock();
    defer self.guard.unlock();

    if (std.mem.indexOfScalar(u32, &self.ids, stream_id) != null) {
        return false;
    }

    const free = std.mem.indexOfScalar(u32, &self.ids, 0) orelse return false;
    self.ids[free] = stream_id;
    return true;
}

/// Records `stream_id` ending and returns whether it counted until now.
///
/// ```zig
/// if (streams.end(stream_id)) exchange.endExchange();
/// ```
pub fn end(self: *StreamsInFlight, stream_id: u32) bool {
    if (stream_id == 0) {
        return false;
    }

    self.lock();
    defer self.guard.unlock();

    const index = std.mem.indexOfScalar(u32, &self.ids, stream_id) orelse return false;
    self.ids[index] = 0;
    return true;
}

fn lock(self: *StreamsInFlight) void {
    while (!self.guard.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

test "a stream counts once from its start to its first end" {
    var streams: StreamsInFlight = .{};

    try std.testing.expect(streams.start(1));
    try std.testing.expect(!streams.start(1));
    try std.testing.expect(streams.end(1));
    try std.testing.expect(!streams.end(1));
    try std.testing.expect(!streams.end(3));
    try std.testing.expect(!streams.start(0));
}

test "a stream past the table is not counted, and a freed entry takes the next" {
    var streams: StreamsInFlight = .{};

    for (0..capacity) |index| {
        try std.testing.expect(streams.start(@intCast(2 * index + 1)));
    }

    try std.testing.expect(!streams.start(2 * capacity + 1));
    try std.testing.expect(!streams.end(2 * capacity + 1));
    try std.testing.expect(streams.end(1));
    try std.testing.expect(streams.start(2 * capacity + 1));
}
