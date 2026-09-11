//! Bounded ownership transfer between history producers and the worker.

const std = @import("std");
const Channel = @import("Channel.zig");
const CountersType = @import("Counters.zig");
const SessionFinishedType = @import("SessionFinished.zig");
const PrunedType = @import("Pruned.zig");

pub const request_capacity = 64;
pub const response_capacity = 4;

test "accepted requests transfer to the worker and release their queue depth" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    var metrics: CountersType = .{};
    const finished: SessionFinishedType = .{ .id = @splat(1), .finished_at_ms = 42 };

    try std.testing.expect(channel.submit(.{
        .io = io,
        .request = .{ .session_finished = finished },
        .metrics = &metrics,
    }));
    const request = try channel.receiveRequest(io, &metrics);

    try std.testing.expectEqual(finished, request.session_finished);
    try std.testing.expectEqual(@as(u64, 0), metrics.snapshot(true).queued);
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot(true).queue_high_water);
}

test "a full request queue refuses work without exceeding its bound" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    var metrics: CountersType = .{};

    for (0..request_capacity) |index| {
        try std.testing.expect(channel.submit(.{
            .io = io,
            .request = .{ .session_finished = .{ .id = @splat(@intCast(index)), .finished_at_ms = @intCast(index) } },
            .metrics = &metrics,
        }));
    }

    try std.testing.expect(!channel.submit(.{
        .io = io,
        .request = .{ .session_finished = .{ .id = @splat(0xff), .finished_at_ms = 65 } },
        .metrics = &metrics,
    }));

    const current = metrics.snapshot(true);

    try std.testing.expectEqual(@as(u64, request_capacity), current.queued);
    try std.testing.expectEqual(@as(u64, request_capacity), current.queue_high_water);
    try std.testing.expectEqual(@as(u64, 1), current.dropped);
}

test "responses cross the channel without changing their correlation" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    const expected: PrunedType = .{
        .request_id = @enumFromInt(7),
        .origin = .{ .client = .{ .id = 3, .generation = 4 }, .close_after_reply = false },
        .removed = 9,
    };

    try channel.sendResponse(io, .{ .pruned = expected });
    const response = try channel.receiveResponse(io);

    try std.testing.expectEqual(expected, response.pruned);
}
