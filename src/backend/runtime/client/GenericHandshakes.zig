const std = @import("std");

/// Creates the runtime-owned table of accepted connections whose handshake
/// actors are in flight, one slot each, so clients that connect at once
/// negotiate independently. A slot's connection is borrowed by its actor
/// until the completion takes it back; which slots are taken, and since
/// when, is known to the main thread alone, which never reads a borrowed
/// connection by value.
///
/// ```zig
/// var handshakes: Type(Connection, 8) = .{};
/// const slot = handshakes.begin(connection, now_ms) orelse return;
/// ```
pub fn Type(comptime Connection: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const slots = capacity;

        connections: [capacity]Connection = undefined,
        busy: std.bit_set.IntegerBitSet(capacity) = .initEmpty(),
        /// Monotonic milliseconds at which each slot's handshake started.
        started_ms: [capacity]i64 = @splat(0),

        /// Handshakes in flight.
        ///
        /// ```zig
        /// const pending = handshakes.count();
        /// ```
        pub fn count(self: *const Self) usize {
            return self.busy.count();
        }

        /// Reports whether any handshake actor still borrows a connection.
        ///
        /// ```zig
        /// if (handshakes.isPending()) {
        ///     return;
        /// }
        /// ```
        pub fn isPending(self: *const Self) bool {
            return self.busy.count() != 0;
        }

        /// Returns the connection a handshake actor borrows in `slot`, if
        /// any. Shutdown may use it to unblock the actor but must not
        /// deinitialize it.
        ///
        /// ```zig
        /// if (handshakes.pendingConnection(slot)) |connection| {
        ///     connection.shutdown(io);
        /// }
        /// ```
        pub fn pendingConnection(self: *Self, slot: usize) ?*Connection {
            if (!self.busy.isSet(slot)) {
                return null;
            }

            return &self.connections[slot];
        }

        /// The first handshake still in flight `deadline_ms` after it
        /// started, at or after `from`.
        ///
        /// ```zig
        /// var from: usize = 0;
        /// while (handshakes.expired(now_ms, 2_000, from)) |slot| : (from = slot + 1) {}
        /// ```
        pub fn expired(self: *const Self, now_ms: i64, deadline_ms: i64, from: usize) ?usize {
            for (from..capacity) |slot| {
                if (self.busy.isSet(slot) and now_ms - self.started_ms[slot] >= deadline_ms) {
                    return slot;
                }
            }

            return null;
        }

        /// Moves an accepted connection into a free slot and returns it, or
        /// null when every slot is taken.
        ///
        /// ```zig
        /// const slot = handshakes.begin(connection, now_ms) orelse return;
        /// ```
        pub fn begin(self: *Self, connection: Connection, now_ms: i64) ?usize {
            var free = self.busy.complement().iterator(.{});
            const slot = free.next() orelse return null;
            self.connections[slot] = connection;
            self.started_ms[slot] = now_ms;
            self.busy.set(slot);
            return slot;
        }

        /// Transfers a slot's connection out after its actor has completed
        /// or failed to start, leaving the slot free.
        ///
        /// ```zig
        /// var connection = handshakes.take(slot);
        /// defer connection.deinit(io);
        /// ```
        pub fn take(self: *Self, slot: usize) Connection {
            std.debug.assert(self.busy.isSet(slot));
            self.busy.unset(slot);
            return self.connections[slot];
        }
    };
}

test "handshakes take free slots and name the ones past their deadline" {
    var handshakes: Type(u32, 2) = .{};

    try std.testing.expect(!handshakes.isPending());
    try std.testing.expectEqual(@as(?usize, 0), handshakes.begin(10, 1_000));
    try std.testing.expectEqual(@as(?usize, 1), handshakes.begin(11, 2_500));
    try std.testing.expect(handshakes.begin(12, 2_600) == null);
    try std.testing.expectEqual(@as(usize, 2), handshakes.count());

    try std.testing.expect(handshakes.expired(2_999, 2_000, 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), handshakes.expired(3_000, 2_000, 0));
    try std.testing.expect(handshakes.expired(3_000, 2_000, 1) == null);

    try std.testing.expectEqual(@as(u32, 10), handshakes.take(0));
    try std.testing.expect(handshakes.pendingConnection(0) == null);
    try std.testing.expectEqual(@as(?usize, 0), handshakes.begin(13, 4_000));
    try std.testing.expectEqual(@as(u32, 11), handshakes.pendingConnection(1).?.*);
}
