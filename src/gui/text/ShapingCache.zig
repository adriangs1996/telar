//! Bounded, owned shaping results for one font set at one size. Single-byte
//! ASCII requested for the primary face has collision-free slots; every other
//! run hashes to a small set of ways, so a list of labels whose hashes
//! collide still stays warm, and a full set evicts round-robin. Long runs
//! bypass the cache. Entries include the requested and the resolved face
//! identity; no paint or GPU state is held.
const std = @import("std");
const Entry = @import("ShapingEntry.zig");
const ShapedRun = @import("ShapedRun.zig");
const Key = @import("ShapingKey.zig");
const Cache = @This();

pub const capacity = 256;
const ascii_capacity = 128;
pub const ways = 4;
const sets = (capacity - ascii_capacity) / ways;
entries: []Entry,
/// Next way each set replaces when none is free.
victims: [sets]u8 = @splat(0),

pub fn init(allocator: std.mem.Allocator) !Cache {
    const entries = try allocator.alloc(Entry, capacity);
    for (entries) |*entry| {
        entry.len = 0;
    }

    return .{ .entries = entries };
}

pub fn deinit(cache: *Cache, allocator: std.mem.Allocator) void {
    allocator.free(cache.entries);
}

/// Invalidates font-dependent results. Example: `cache.clear();`
pub fn clear(cache: *Cache) void {
    for (cache.entries) |*entry| {
        entry.len = 0;
    }
}

fn setOf(key: Key) ?usize {
    const text = key.text;
    if (text.len == 0 or text.len > Entry.max_bytes) {
        return null;
    }

    if (text.len == 1 and text[0] < ascii_capacity and key.face == .primary) {
        return text[0];
    }

    return ascii_capacity + (std.hash.Wyhash.hash(@intFromEnum(key.face), text) % sets) * ways;
}

fn waysOf(cache: *Cache, set: usize) []Entry {
    return if (set < ascii_capacity) cache.entries[set..][0..1] else cache.entries[set..][0..ways];
}

fn matches(entry: *const Entry, key: Key) bool {
    return entry.len == key.text.len and entry.preferred == key.face and std.mem.eql(u8, entry.text[0..entry.len], key.text);
}

/// Borrows until the next insertion or clear.
/// Example: `const hit = cache.find(.{ .text = text, .face = .sans });`
pub fn find(cache: *Cache, key: Key) ?ShapedRun {
    const set = setOf(key) orelse return null;
    for (cache.waysOf(set)) |*entry| {
        if (matches(entry, key)) {
            return entry.view();
        }
    }

    return null;
}

/// Copies the borrowed HarfBuzz result. Example: `cache.remember(.{ .text = text }, shaped);`
pub fn remember(cache: *Cache, key: Key, shaped: ShapedRun) void {
    const set = setOf(key) orelse return;
    if (shaped.glyphs.len > Entry.max_glyphs) {
        return;
    }

    const entry = cache.victim(set, key);

    @memcpy(entry.text[0..key.text.len], key.text);
    @memcpy(entry.glyphs[0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(entry.positions[0..shaped.positions.len], shaped.positions);
    entry.font = shaped.font;
    entry.preferred = key.face;
    entry.columns = shaped.columns;
    entry.len = @intCast(key.text.len);
    entry.count = @intCast(shaped.glyphs.len);
}

// Reuses the key's own entry or a free way before evicting round-robin.
fn victim(cache: *Cache, set: usize, key: Key) *Entry {
    const candidates = cache.waysOf(set);
    for (candidates) |*entry| {
        if (entry.len == 0 or matches(entry, key)) {
            return entry;
        }
    }

    const index = (set - ascii_capacity) / ways;
    const chosen = &candidates[cache.victims[index]];
    cache.victims[index] = (cache.victims[index] + 1) % ways;
    return chosen;
}

test "colliding runs share a set and only a full set evicts" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    const shaped: ShapedRun = .{ .font = .sans, .columns = 1, .glyphs = &.{}, .positions = &.{} };
    // Both hash to the same set with the sans face (checked with Wyhash).
    cache.remember(.{ .text = "alpha", .face = .sans }, shaped);
    cache.remember(.{ .text = "beta", .face = .sans }, shaped);
    try std.testing.expect(cache.find(.{ .text = "alpha", .face = .sans }) != null);
    try std.testing.expect(cache.find(.{ .text = "beta", .face = .sans }) != null);
    try std.testing.expect(cache.find(.{ .text = "alpha", .face = .primary }) == null);

    cache.remember(.{ .text = "alpha", .face = .sans }, shaped);
    try std.testing.expect(cache.find(.{ .text = "beta", .face = .sans }) != null);
    cache.remember(.{ .text = "a", .face = .primary }, shaped);
    try std.testing.expect(cache.find(.{ .text = "a", .face = .primary }) != null);
    try std.testing.expect(cache.find(.{ .text = "x" ** (Entry.max_bytes + 1), .face = .sans }) == null);
}
