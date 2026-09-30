const std = @import("std");

/// Creates the runtime-owned table of accepted connections whose handshake
/// actors are in flight, one slot each, so clients that connect at once
/// negotiate independently. A slot's connection is borrowed by its actor
/// until the completion takes it back.
///
/// ```zig
/// var handshakes: Type(Connection, 8) = .{};
/// const slot = handshakes.begin(connection) orelse return;
/// ```
pub fn Type(comptime Connection: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const slots = capacity;

        connections: [capacity]?Connection = @splat(null),
        /// Admission order, so the oldest handshake is the one interrupted
        /// when every slot is taken.
        started: [capacity]u64 = @splat(0),
        next_start: u64 = 0,

        /// Reports whether any handshake actor still borrows a connection.
        ///
        /// ```zig
        /// if (handshakes.isPending()) {
        ///     return;
        /// }
        /// ```
        pub fn isPending(self: *const Self) bool {
            for (self.connections) |connection| {
                if (connection != null) {
                    return true;
                }
            }

            return false;
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
            if (self.connections[slot] == null) {
                return null;
            }

            return &self.connections[slot].?;
        }

        /// The slot of the handshake admitted first, when every slot is
        /// taken; null while one is free.
        ///
        /// ```zig
        /// if (handshakes.oldestWhenFull()) |slot| interrupt(slot);
        /// ```
        pub fn oldestWhenFull(self: *const Self) ?usize {
            var oldest: ?usize = null;
            for (self.connections, 0..) |connection, slot| {
                if (connection == null) {
                    return null;
                }

                if (oldest == null or self.started[slot] < self.started[oldest.?]) {
                    oldest = slot;
                }
            }

            return oldest;
        }

        /// Moves an accepted connection into a free slot and returns it, or
        /// null when every slot is taken.
        ///
        /// ```zig
        /// const slot = handshakes.begin(connection) orelse return;
        /// ```
        pub fn begin(self: *Self, connection: Connection) ?usize {
            for (&self.connections, 0..) |*entry, slot| {
                if (entry.* != null) {
                    continue;
                }

                entry.* = connection;
                self.started[slot] = self.next_start;
                self.next_start += 1;
                return slot;
            }

            return null;
        }

        /// Transfers a slot's connection out after its actor has completed
        /// or failed to start, leaving the slot free.
        ///
        /// ```zig
        /// var connection = handshakes.take(slot);
        /// defer connection.deinit(io);
        /// ```
        pub fn take(self: *Self, slot: usize) Connection {
            std.debug.assert(self.connections[slot] != null);
            const connection = self.connections[slot].?;
            self.connections[slot] = null;
            return connection;
        }
    };
}

test "handshakes take free slots and name the oldest only when full" {
    var handshakes: Type(u32, 2) = .{};

    try std.testing.expect(!handshakes.isPending());
    try std.testing.expectEqual(@as(?usize, 0), handshakes.begin(10));
    try std.testing.expect(handshakes.oldestWhenFull() == null);
    try std.testing.expectEqual(@as(?usize, 1), handshakes.begin(11));
    try std.testing.expectEqual(@as(?usize, 0), handshakes.oldestWhenFull());
    try std.testing.expect(handshakes.begin(12) == null);

    try std.testing.expectEqual(@as(u32, 10), handshakes.take(0));
    try std.testing.expectEqual(@as(?usize, 0), handshakes.begin(13));
    try std.testing.expectEqual(@as(?usize, 1), handshakes.oldestWhenFull());
    try std.testing.expectEqual(@as(u32, 11), handshakes.pendingConnection(1).?.*);
}
