//! Allocation-free indices for bounded stores on latency-sensitive paths.

const GenericSlotIndex = @import("GenericSlotIndex.zig").Type;
const std = @import("std");

test "slot index preserves probe chains across removal and reuse" {
    var index: GenericSlotIndex(8) = .{};
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

test "slot index misses terminate after unbounded create and remove churn" {
    var index: GenericSlotIndex(128) = .{};
    const live: [4]u64 = .{ 1, 2, 3, 4 };
    for (live, 0..) |key, slot| {
        index.put(key, slot);
    }

    var next: u64 = 5;
    for (0..10_000) |_| {
        index.put(next, 4);
        try std.testing.expectEqual(@as(?usize, 4), index.get(next));
        index.remove(next);
        next += 1;
    }

    try std.testing.expectEqual(@as(?usize, null), index.get(next));
    try std.testing.expectEqual(@as(?usize, null), index.get(next - 1));
    for (live, 0..) |key, slot| {
        try std.testing.expectEqual(@as(?usize, slot), index.get(key));
    }
}

test "slot index agrees with a reference map under random churn" {
    var index: GenericSlotIndex(16) = .{};
    var reference: [8]?u64 = @splat(null);
    var random = std.Random.DefaultPrng.init(0x7e1a);
    const rng = random.random();
    for (0..200_000) |_| {
        const slot = rng.uintLessThan(usize, reference.len);
        if (reference[slot]) |key| {
            index.remove(key);
            reference[slot] = null;
        } else {
            const key = rng.intRangeAtMost(u64, 1, 64);
            if (index.get(key) == null) {
                index.put(key, slot);
                reference[slot] = key;
            }
        }

        const probe = rng.intRangeAtMost(u64, 1, 64);
        var expected: ?usize = null;
        for (reference, 0..) |candidate, candidate_slot| {
            if (candidate == probe) {
                expected = candidate_slot;
            }
        }

        try std.testing.expectEqual(expected, index.get(probe));
    }
}
