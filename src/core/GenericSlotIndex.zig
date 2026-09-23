const std = @import("std");

/// Fixed-capacity open-addressed map from a nonzero raw id to a byte-sized
/// store slot. Linear probing with backward-shift deletion keeps every probe
/// chain free of tombstones, so a miss always ends at an empty key while the
/// index holds fewer than `capacity` entries.
pub fn Type(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        pub const Self = @This();
        pub const empty_key: u64 = 0;

        keys: [capacity]u64 = @splat(empty_key),
        slots: [capacity]u8 = undefined,

        /// Inserts an absent key; the owning store bounds occupancy below
        /// capacity. Example: `index.put(raw_id, slot);`
        pub fn put(index: *Self, key: u64, slot: usize) void {
            std.debug.assert(key != empty_key);
            var probe = home(key);
            for (0..capacity) |_| {
                const found = index.keys[probe];
                if (found == empty_key) {
                    index.keys[probe] = key;
                    index.slots[probe] = @intCast(slot);
                    return;
                }

                std.debug.assert(found != key);
                probe = next(probe);
            }

            unreachable;
        }

        /// Example: `const slot = index.get(raw_id) orelse return null;`
        pub fn get(index: *const Self, key: u64) ?usize {
            var probe = home(key);
            for (0..capacity) |_| {
                const found = index.keys[probe];
                if (found == key) {
                    return index.slots[probe];
                }

                if (found == empty_key) {
                    return null;
                }

                probe = next(probe);
            }

            return null;
        }

        /// Removes a key and shifts later members of its cluster back into
        /// the hole, so no lookup ever has to skip a deleted entry.
        /// Example: `index.remove(raw_id);`
        pub fn remove(index: *Self, key: u64) void {
            var hole = index.find(key) orelse return;
            var probe = next(hole);
            for (0..capacity) |_| {
                const found = index.keys[probe];
                if (found == empty_key) {
                    break;
                }

                if (!between(hole, home(found), probe)) {
                    index.keys[hole] = found;
                    index.slots[hole] = index.slots[probe];
                    hole = probe;
                }

                probe = next(probe);
            }

            index.keys[hole] = empty_key;
        }

        pub fn reset(index: *Self) void {
            index.keys = @splat(empty_key);
        }

        fn find(index: *const Self, key: u64) ?usize {
            var probe = home(key);
            for (0..capacity) |_| {
                const found = index.keys[probe];
                if (found == key) {
                    return probe;
                }

                if (found == empty_key) {
                    return null;
                }

                probe = next(probe);
            }

            return null;
        }

        fn home(key: u64) usize {
            return @intCast(std.hash.int(key) % capacity);
        }

        fn next(probe: usize) usize {
            return (probe + 1) % capacity;
        }

        /// Whether `position` lies cyclically in `(start, end]`: an entry whose
        /// home is there must stay after the hole to remain reachable.
        fn between(start: usize, position: usize, end: usize) bool {
            if (start <= end) {
                return start < position and position <= end;
            }

            return start < position or position <= end;
        }
    };
}
