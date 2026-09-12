//! Bounded, owned shaping results for one font at one size. Collisions replace
//! entries; long runs bypass the cache. No position, color or GPU state is held.
const std = @import("std");
const Entry = @import("ShapingEntry.zig");
const ShapedRun = @import("ShapedRun.zig");
const Cache = @This();

pub const capacity = 256;
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

fn entryFor(cache: *Cache, text: []const u8) ?*Entry {
    if (text.len == 0 or text.len > Entry.max_bytes) {
        return null;
    }

    return &cache.entries[std.hash.Wyhash.hash(0, text) % capacity];
}

/// Borrows until the next insertion or clear. Example: `const hit = cache.find(text);`
pub fn find(cache: *Cache, text: []const u8) ?ShapedRun {
    const entry = cache.entryFor(text) orelse return null;
    if (entry.len != text.len or !std.mem.eql(u8, entry.text[0..entry.len], text)) {
        return null;
    }

    return entry.view();
}

/// Copies the borrowed HarfBuzz result. Example: `cache.remember(text, shaped);`
pub fn remember(cache: *Cache, text: []const u8, shaped: ShapedRun) void {
    const entry = cache.entryFor(text) orelse return;
    if (shaped.glyphs.len > Entry.max_glyphs) {
        return;
    }

    @memcpy(entry.text[0..text.len], text);
    @memcpy(entry.glyphs[0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(entry.positions[0..shaped.positions.len], shaped.positions);
    entry.len = @intCast(text.len);
    entry.count = @intCast(shaped.glyphs.len);
}
