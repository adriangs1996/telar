const std = @import("std");
const GenericDropQueue = @import("GenericDropQueue.zig").Type;
const QueueMetrics = @import("QueueMetrics.zig");

const capacity = 256;
const Queue = GenericDropQueue(u64, capacity);
const batch_size = 64;

fn publishBatch(queue: *Queue, io: std.Io, first: u64) void {
    for (0..batch_size) |index| {
        _ = queue.publish(io, first + @as(u64, @intCast(index)));
    }
}

test "bounded publication records depth high water and loss" {
    var queue: Queue = undefined;
    queue.init();

    for (0..capacity) |index| {
        try std.testing.expect(queue.publish(std.testing.io, index));
    }

    try std.testing.expect(!queue.publish(std.testing.io, capacity));
    try std.testing.expectEqualDeep(QueueMetrics{
        .queued = capacity,
        .high_water = capacity,
        .dropped = 1,
    }, queue.metrics());

    for (0..capacity) |index| {
        try std.testing.expectEqual(@as(u64, index), try queue.receive(std.testing.io));
    }

    try std.testing.expectEqual(@as(u64, 0), queue.metrics().queued);
}

test "concurrent publishers cannot reserve beyond the fixed bound" {
    const publisher_count = 8;
    var queue: Queue = undefined;
    queue.init();
    var publishers: std.Io.Group = .init;

    for (0..publisher_count) |index| {
        try publishers.concurrent(
            std.testing.io,
            publishBatch,
            .{
                &queue,
                std.testing.io,
                @as(u64, @intCast(index * batch_size)),
            },
        );
    }

    try publishers.await(std.testing.io);

    try std.testing.expectEqualDeep(QueueMetrics{
        .queued = capacity,
        .high_water = capacity,
        .dropped = publisher_count * batch_size - capacity,
    }, queue.metrics());
}

test "direct handoff reserves depth before a waiting receiver releases it" {
    var queue: Queue = undefined;
    queue.init();
    var receiver = try std.testing.io.concurrent(Queue.receive, .{ &queue, std.testing.io });

    try std.testing.expect(queue.publish(std.testing.io, 9));

    try std.testing.expectEqual(@as(u64, 9), try receiver.await(std.testing.io));
    try std.testing.expectEqualDeep(QueueMetrics{
        .queued = 0,
        .high_water = 1,
        .dropped = 0,
    }, queue.metrics());
}

test "try receive returns buffered items without waiting" {
    var queue: Queue = undefined;
    queue.init();

    try std.testing.expect(queue.tryReceive(std.testing.io) == null);
    try std.testing.expect(queue.publish(std.testing.io, 3));

    try std.testing.expectEqual(@as(?u64, 3), queue.tryReceive(std.testing.io));
    try std.testing.expect(queue.tryReceive(std.testing.io) == null);
    try std.testing.expectEqual(@as(u64, 0), queue.metrics().queued);
}

test "closure drains buffered items then rejects delivery and publication" {
    var queue: Queue = undefined;
    queue.init();
    try std.testing.expect(queue.publish(std.testing.io, 4));

    queue.close(std.testing.io);

    try std.testing.expectEqual(@as(u64, 4), try queue.receive(std.testing.io));
    try std.testing.expectError(error.Closed, queue.receive(std.testing.io));
    try std.testing.expect(!queue.publish(std.testing.io, 5));
    try std.testing.expectEqualDeep(QueueMetrics{
        .queued = 0,
        .high_water = 1,
        .dropped = 1,
    }, queue.metrics());
}

test "closure wakes a receiver waiting on an empty queue" {
    var queue: Queue = undefined;
    queue.init();
    var receiver = try std.testing.io.concurrent(Queue.receive, .{ &queue, std.testing.io });

    queue.close(std.testing.io);

    try std.testing.expectError(error.Closed, receiver.await(std.testing.io));
}
