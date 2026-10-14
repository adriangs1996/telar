//! Bounded negative cache of graphemes no installed face covers, so a miss
//! costs one native lookup rather than one per cold shaping. Eight-way set
//! associative by a 64-bit hash: a screen of distinct uncovered graphemes
//! fits without two of them evicting each other on every reshaping; a ninth
//! in one set replaces the set's oldest, which only makes that lookup
//! happen again, never a wrong face.
const std = @import("std");
const GraphemeMisses = @This();

pub const capacity = 4096;
const ways = 8;
const sets = capacity / ways;

hashes: [capacity]u64 = @splat(0),
next: [sets]u3 = @splat(0),

/// Example: `if (misses.contains(text)) { return .primary; }`
pub fn contains(self: *const GraphemeMisses, text: []const u8) bool {
    const digest = hash(text);
    for (self.set(digest)) |stored| {
        if (stored == digest) {
            return true;
        }
    }

    return false;
}

/// Example: `misses.remember(text);`
pub fn remember(self: *GraphemeMisses, text: []const u8) void {
    const digest = hash(text);
    const index = digest % sets;
    const entries = self.hashes[index * ways ..][0..ways];
    for (entries) |*entry| {
        if (entry.* == digest) {
            return;
        }

        if (entry.* == 0) {
            entry.* = digest;
            return;
        }
    }

    entries[self.next[index]] = digest;
    self.next[index] +%= 1;
}

fn set(self: *const GraphemeMisses, digest: u64) *const [ways]u64 {
    return self.hashes[(digest % sets) * ways ..][0..ways];
}

// Never zero, so an empty slot never matches.
fn hash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7e1a, text) | 1;
}
