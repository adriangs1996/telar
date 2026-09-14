//! Bounded negative cache of graphemes no installed face covers, so a miss
//! costs one native lookup rather than one per cold shaping. Direct-mapped
//! by a 64-bit hash: a colliding grapheme replaces the older entry, which
//! only makes that lookup happen again, never a wrong face.
const std = @import("std");
const GraphemeMisses = @This();

pub const capacity = 256;

hashes: [capacity]u64 = @splat(0),

/// Example: `if (misses.contains(text)) { return .primary; }`
pub fn contains(misses: *const GraphemeMisses, text: []const u8) bool {
    const digest = hash(text);
    return misses.hashes[digest % capacity] == digest;
}

/// Example: `misses.remember(text);`
pub fn remember(misses: *GraphemeMisses, text: []const u8) void {
    const digest = hash(text);
    misses.hashes[digest % capacity] = digest;
}

// Never zero, so an empty slot never matches.
fn hash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7e1a, text) | 1;
}

test "a remembered grapheme is found and a collision only forgets the older one" {
    var misses: GraphemeMisses = .{};
    try std.testing.expect(!misses.contains("\u{23f5}"));
    misses.remember("\u{23f5}");
    try std.testing.expect(misses.contains("\u{23f5}"));
    try std.testing.expect(!misses.contains("\u{23f4}"));
    misses.hashes[hash("\u{23f5}") % capacity] = 0x1234_5679;
    try std.testing.expect(!misses.contains("\u{23f5}"));
    misses.remember("\u{23f5}");
    try std.testing.expect(misses.contains("\u{23f5}"));
}
