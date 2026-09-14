//! Bounded, owned shaping results for one font set at one size. Collisions replace
//! hashed entries; single-byte ASCII requested for the primary face has
//! collision-free slots. Long runs bypass the cache. Entries include the
//! requested and the resolved face identity; no paint or GPU state is held.
const std = @import("std");
const Entry = @import("ShapingEntry.zig");
const ShapedRun = @import("ShapedRun.zig");
const Key = @import("ShapingKey.zig");
const Cache = @This();

pub const capacity = 256;
const ascii_capacity = 128;
entries: []Entry,

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

fn entryFor(cache: *Cache, key: Key) ?*Entry {
    const text = key.text;
    if (text.len == 0 or text.len > Entry.max_bytes) {
        return null;
    }

    if (text.len == 1 and text[0] < ascii_capacity and key.face == .primary) {
        return &cache.entries[text[0]];
    }

    return &cache.entries[ascii_capacity + std.hash.Wyhash.hash(@intFromEnum(key.face), text) % (capacity - ascii_capacity)];
}

/// Borrows until the next insertion or clear.
/// Example: `const hit = cache.find(.{ .text = text, .face = .sans });`
pub fn find(cache: *Cache, key: Key) ?ShapedRun {
    const entry = cache.entryFor(key) orelse return null;
    if (entry.len != key.text.len or entry.preferred != key.face or !std.mem.eql(u8, entry.text[0..entry.len], key.text)) {
        return null;
    }

    return entry.view();
}

/// Copies the borrowed HarfBuzz result. Example: `cache.remember(.{ .text = text }, shaped);`
pub fn remember(cache: *Cache, key: Key, shaped: ShapedRun) void {
    const entry = cache.entryFor(key) orelse return;
    if (shaped.glyphs.len > Entry.max_glyphs) {
        return;
    }

    @memcpy(entry.text[0..key.text.len], key.text);
    @memcpy(entry.glyphs[0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(entry.positions[0..shaped.positions.len], shaped.positions);
    entry.font = shaped.font;
    entry.preferred = key.face;
    entry.columns = shaped.columns;
    entry.len = @intCast(key.text.len);
    entry.count = @intCast(shaped.glyphs.len);
}
