//! Recent glyphs that cannot fit the current atlas page. Four alternatives per
//! bucket avoid immediate collisions while keeping every lookup bounded.
const std = @import("std");
const Cache = @This();

pub const capacity = 256;
const ways = 4;
const buckets = capacity / ways;
keys: [capacity]u64 = @splat(0),
next: [buckets]u2 = @splat(0),

/// Matches the complete glyph/size/style key, never a hash alone.
/// Example: `if (failures.contains(key)) return error.AtlasFull;`
pub fn contains(cache: *const Cache, key: u64) bool {
    std.debug.assert(key != 0);
    const first = bucket(key) * ways;
    for (cache.keys[first..][0..ways]) |stored| {
        if (stored == key) {
            return true;
        }
    }

    return false;
}

/// Replaces only a bounded recent failure; successful glyphs stay in the atlas.
/// Example: `failures.remember(key);`
pub fn remember(cache: *Cache, key: u64) void {
    std.debug.assert(key != 0);
    const index = bucket(key);
    const entries = cache.keys[index * ways ..][0..ways];
    for (entries) |*entry| {
        if (entry.* == key) {
            return;
        }

        if (entry.* == 0) {
            entry.* = key;
            return;
        }
    }

    entries[cache.next[index]] = key;
    cache.next[index] +%= 1;
}

fn bucket(key: u64) usize {
    return std.hash.int(key) % buckets;
}

test "glyph failures retain exact keys with bounded replacement" {
    var cache: Cache = .{};
    try std.testing.expect(!cache.contains(1));
    for (1..4096) |key| {
        cache.remember(key);
        try std.testing.expect(cache.contains(key));
        try std.testing.expect(!cache.contains(key + 4096));
    }

    cache = .{};
    try std.testing.expect(!cache.contains(4095));
}
