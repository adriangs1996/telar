//! Bounded semantic state for active HTTP/2 streams.

const std = @import("std");

pub const max_tracked_streams = 128;

pub const Response = struct {
    stream_id: u32,
    status_code: u16,
    sse_body: bool,
};

pub const Tracker = struct {
    responses: [max_tracked_streams]Response = @splat(.{
        .stream_id = 0,
        .status_code = 0,
        .sse_body = false,
    }),
    requests: [max_tracked_streams]u32 = @splat(0),

    pub fn startRequest(tracker: *Tracker, stream_id: u32) bool {
        if (stream_id == 0) {
            return false;
        }

        var free: ?*u32 = null;

        for (&tracker.requests) |*slot| {
            if (slot.* == stream_id) {
                return false;
            }

            if (slot.* == 0 and free == null) {
                free = slot;
            }
        }

        const destination = free orelse return false;
        destination.* = stream_id;
        return true;
    }

    pub fn finishRequest(tracker: *Tracker, stream_id: u32) void {
        for (&tracker.requests) |*slot| {
            if (slot.* != stream_id) {
                continue;
            }

            slot.* = 0;
            return;
        }
    }

    pub fn setResponse(tracker: *Tracker, response: Response) bool {
        if (response.stream_id == 0) {
            return false;
        }

        var free: ?*Response = null;

        for (&tracker.responses) |*entry| {
            if (entry.stream_id == response.stream_id) {
                entry.* = response;
                return true;
            }

            if (entry.stream_id == 0 and free == null) {
                free = entry;
            }
        }

        const destination = free orelse return false;
        destination.* = response;
        return true;
    }

    pub fn status(tracker: *const Tracker, stream_id: u32) u16 {
        for (tracker.responses) |entry| {
            if (entry.stream_id == stream_id) {
                return entry.status_code;
            }
        }

        return 0;
    }

    pub fn hasObservableSseBody(tracker: *const Tracker, stream_id: u32) bool {
        for (tracker.responses) |entry| {
            if (entry.stream_id == stream_id) {
                return entry.sse_body;
            }
        }

        return false;
    }

    pub fn hasActiveResponses(tracker: *const Tracker) bool {
        for (tracker.responses) |entry| {
            if (entry.stream_id != 0) {
                return true;
            }
        }

        return false;
    }

    pub fn finishResponse(tracker: *Tracker, stream_id: u32) void {
        for (&tracker.responses) |*entry| {
            if (entry.stream_id != stream_id) {
                continue;
            }

            entry.* = .{
                .stream_id = 0,
                .status_code = 0,
                .sse_body = false,
            };
            return;
        }
    }
};

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
