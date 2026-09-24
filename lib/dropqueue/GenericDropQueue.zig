//! Fixed storage behind `std.Io.Queue` with lock-free depth admission.
//! Publication never waits: a full or closed queue refuses the item, counts
//! the drop and hands ownership back to the caller.
const std = @import("std");
const QueueMetrics = @import("QueueMetrics.zig");

/// Items are copied in and out; an item that owns memory is freed by the
/// caller when `publish` refuses it or when it is received.
/// Example: `const Events = GenericDropQueue(Event, 256);`
pub fn Type(comptime Item: type, comptime capacity: usize) type {
    return struct {
        const Queue = @This();

        storage: [capacity]Item = undefined,
        items: std.Io.Queue(Item) = undefined,
        queued: std.atomic.Value(u64) = .init(0),
        high_water: std.atomic.Value(u64) = .init(0),
        dropped: std.atomic.Value(u64) = .init(0),

        /// Initializes the queue at its final address; the queue points into
        /// its own storage.
        ///
        /// ```zig
        /// var queue: Events = undefined;
        /// queue.init();
        /// ```
        pub fn init(self: *Queue) void {
            self.* = .{};
            self.items = .init(&self.storage);
        }

        /// Queues one item without waiting. Returns false when the queue is
        /// full or closed; the drop is counted and the item stays the
        /// caller's.
        ///
        /// ```zig
        /// if (!queue.publish(io, event)) event.deinit();
        /// ```
        pub fn publish(self: *Queue, io: std.Io, item: Item) bool {
            // A waiting receiver may consume a direct handoff before `put`
            // returns, so depth must be reserved before publication.
            const depth = self.reserve() orelse {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            };

            const published = self.items.put(io, &.{item}, 0) catch 0;
            if (published == 0) {
                self.release();
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            }

            _ = self.high_water.fetchMax(depth, .monotonic);
            return true;
        }

        /// Waits for the next item. After `close`, buffered items are still
        /// delivered and then `error.Closed` is returned.
        ///
        /// ```zig
        /// const event = try queue.receive(io);
        /// ```
        pub fn receive(self: *Queue, io: std.Io) anyerror!Item {
            const item = try self.items.getOne(io);
            self.release();

            return item;
        }

        /// Returns the next buffered item, or null when none is buffered.
        /// Never waits.
        ///
        /// ```zig
        /// while (queue.tryReceive(io)) |event| consume(event);
        /// ```
        pub fn tryReceive(self: *Queue, io: std.Io) ?Item {
            var items: [1]Item = undefined;
            const count = self.items.getUncancelable(io, &items, 0) catch return null;
            if (count == 0) {
                return null;
            }

            self.release();
            return items[0];
        }

        /// Refuses future publication and wakes receivers once buffered
        /// items are read.
        ///
        /// ```zig
        /// queue.close(io);
        /// ```
        pub fn close(self: *Queue, io: std.Io) void {
            self.items.close(io);
        }

        /// Returns a lock-free snapshot of reserved depth, its high-water
        /// mark and publication loss.
        ///
        /// ```zig
        /// const snapshot = queue.metrics();
        /// ```
        pub fn metrics(self: *const Queue) QueueMetrics {
            return .{
                .queued = self.queued.load(.monotonic),
                .high_water = self.high_water.load(.monotonic),
                .dropped = self.dropped.load(.monotonic),
            };
        }

        fn reserve(self: *Queue) ?u64 {
            var current = self.queued.load(.monotonic);

            while (current < capacity) {
                if (self.queued.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                    current = observed;
                    continue;
                }

                return current + 1;
            }

            return null;
        }

        fn release(self: *Queue) void {
            const previous = self.queued.fetchSub(1, .monotonic);
            std.debug.assert(previous != 0);
        }
    };
}
