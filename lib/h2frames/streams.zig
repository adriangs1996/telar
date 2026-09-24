//! Bounded semantic state for active HTTP/2 streams.

const std = @import("std");

pub const max_tracked_streams = 128;

pub const Response = @import("Response.zig");

pub const Tracker = @import("Tracker.zig");

test "request tracking is idempotent bounded and reusable" {
    var tracker: Tracker = .{};

    try std.testing.expect(!tracker.startRequest(0));

    for (0..max_tracked_streams) |index| {
        try std.testing.expect(tracker.startRequest(@intCast(2 * index + 1)));
    }

    try std.testing.expect(!tracker.startRequest(1));
    try std.testing.expect(!tracker.startRequest(@intCast(2 * max_tracked_streams + 1)));

    tracker.finishRequest(1);
    try std.testing.expect(tracker.startRequest(@intCast(2 * max_tracked_streams + 1)));
}

test "response tracking updates metadata and releases capacity" {
    var tracker: Tracker = .{};
    const first: Response = .{ .stream_id = 1, .status_code = 200, .sse_body = true };

    try std.testing.expect(!tracker.hasActiveResponses());
    try std.testing.expect(tracker.setResponse(first));
    try std.testing.expect(tracker.hasActiveResponses());
    try std.testing.expectEqual(@as(u16, 200), tracker.status(1));
    try std.testing.expect(tracker.hasObservableSseBody(1));

    try std.testing.expect(tracker.setResponse(.{
        .stream_id = 1,
        .status_code = 429,
        .sse_body = false,
    }));
    try std.testing.expectEqual(@as(u16, 429), tracker.status(1));
    try std.testing.expect(!tracker.hasObservableSseBody(1));

    tracker.finishResponse(1);
    try std.testing.expect(!tracker.hasActiveResponses());
    try std.testing.expectEqual(@as(u16, 0), tracker.status(1));
}

test "response capacity exhaustion does not replace active streams" {
    var tracker: Tracker = .{};

    for (0..max_tracked_streams) |index| {
        try std.testing.expect(tracker.setResponse(.{
            .stream_id = @intCast(2 * index + 1),
            .status_code = 200,
            .sse_body = false,
        }));
    }

    const overflow: u32 = @intCast(2 * max_tracked_streams + 1);
    try std.testing.expect(!tracker.setResponse(.{
        .stream_id = overflow,
        .status_code = 503,
        .sse_body = false,
    }));
    try std.testing.expectEqual(@as(u16, 0), tracker.status(overflow));
    try std.testing.expectEqual(@as(u16, 200), tracker.status(1));
}
