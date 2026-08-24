//! Allocation-free indices for bounded stores on latency-sensitive paths.

const std = @import("std");

/// Fixed-capacity open-addressed map from a nonzero raw id to a byte-sized
/// store slot. `maxInt(u64)` is reserved as a tombstone.
pub fn SlotIndex(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        pub const Self = @This();
        pub const empty_key: u64 = 0;
        pub const tombstone_key: u64 = std.math.maxInt(u64);

        keys: [capacity]u64 = @splat(empty_key),
        slots: [capacity]u8 = undefined,

        pub fn put(index: *Self, key: u64, slot: usize) void {
            std.debug.assert(key != empty_key and key != tombstone_key);
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                switch (index.keys[probe]) {
                    empty_key, tombstone_key => {
                        index.keys[probe] = key;
                        index.slots[probe] = @intCast(slot);
                        return;
                    },
                    else => std.debug.assert(index.keys[probe] != key),
                }
            }
        }

        pub fn get(index: *const Self, key: u64) ?usize {
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                const found = index.keys[probe];
                if (found == key) return index.slots[probe];
                if (found == empty_key) return null;
            }
        }

        pub fn remove(index: *Self, key: u64) void {
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                const found = index.keys[probe];
                if (found == key) {
                    index.keys[probe] = tombstone_key;
                    return;
                }
                if (found == empty_key) return;
            }
        }

        pub fn reset(index: *Self) void {
            index.keys = @splat(empty_key);
        }
    };
}

test "slot index preserves probe chains across removal and reuse" {
    var index: SlotIndex(8) = .{};
    index.put(1, 0);
    index.put(9, 1);
    index.put(17, 2);
    try std.testing.expectEqual(@as(?usize, 0), index.get(1));
    try std.testing.expectEqual(@as(?usize, 1), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));

    index.remove(9);
    try std.testing.expectEqual(@as(?usize, null), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));
    index.put(33, 5);
    try std.testing.expectEqual(@as(?usize, 5), index.get(33));

    index.reset();
    try std.testing.expectEqual(@as(?usize, null), index.get(1));
}
