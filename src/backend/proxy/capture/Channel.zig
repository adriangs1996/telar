const dropqueue = @import("dropqueue");
const owned = @import("owned.zig");
const queue = @import("queue.zig");
const std = @import("std");
const Half = owned.Half;
const QueueMetrics = dropqueue.QueueMetrics;
const Halves = dropqueue.GenericDropQueue(*Half, queue.capacity);
const Channel = @This();

halves: Halves = undefined,

/// Initializes fixed queue storage.
///
/// ```zig
/// channel.init();
/// ```
pub fn init(self: *Channel) void {
    self.halves.init();
}

/// Attempts a zero-deadline ownership transfer and frees a rejected half.
///
/// ```zig
/// _ = channel.publish(io, half);
/// ```
pub fn publish(self: *Channel, io: std.Io, half: *Half) bool {
    if (!self.halves.publish(io, half)) {
        half.deinit();
        return false;
    }

    return true;
}

/// Returns the next captured half.
///
/// ```zig
/// const half = try channel.receive(io);
/// ```
pub fn receive(self: *Channel, io: std.Io) anyerror!*Half {
    return self.halves.receive(io);
}

/// Closes the channel and frees all buffered half ownership.
///
/// ```zig
/// channel.close(io);
/// ```
pub fn close(self: *Channel, io: std.Io) void {
    self.halves.close(io);

    while (self.halves.tryReceive(io)) |half| {
        half.deinit();
    }
}

/// Reads queue depth, high-water mark, and capacity drops atomically.
///
/// ```zig
/// const metrics = channel.metrics();
/// ```
pub fn metrics(self: *const Channel) QueueMetrics {
    return self.halves.metrics();
}
