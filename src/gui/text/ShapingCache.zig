//! Bounded, owned shaping results for one font set at one size. Single-byte
//! ASCII requested for the primary face has collision-free slots; every
//! other run hashes into a four-way set, so up to four labels sharing a hash
//! stay cached together instead of evicting one another every frame. A
//! fifth replaces the set's oldest. Long runs bypass the cache. Entries
//! include the requested and the resolved face identity; no paint or GPU
//! state is held.
const std = @import("std");
const Entry = @import("ShapingEntry.zig");
const ShapedRun = @import("ShapedRun.zig");
const Key = @import("ShapingKey.zig");
const Cache = @This();

const ascii_capacity = 128;
const ways = 4;
const sets = 64;
pub const capacity = ascii_capacity + ways * sets;

entries: []Entry,
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

    cache.victims = @splat(0);
}

const Slot = union(enum) {
    dedicated: usize,
    set: usize,
};

fn slotFor(key: Key) ?Slot {
    const text = key.text;
    if (text.len == 0 or text.len > Entry.max_bytes) {
        return null;
    }

    if (text.len == 1 and text[0] < ascii_capacity and key.face == .primary) {
        return .{ .dedicated = text[0] };
    }

    return .{ .set = std.hash.Wyhash.hash(@intFromEnum(key.face), text) % sets };
}

fn matches(entry: *const Entry, key: Key) bool {
    return entry.len == key.text.len and entry.preferred == key.face and std.mem.eql(u8, entry.text[0..entry.len], key.text);
}

fn setEntries(cache: *Cache, set: usize) []Entry {
    const start = ascii_capacity + set * ways;
    return cache.entries[start .. start + ways];
}

/// Borrows until the next insertion or clear.
/// Example: `const hit = cache.find(.{ .text = text, .face = .sans });`
pub fn find(cache: *Cache, key: Key) ?ShapedRun {
    switch (slotFor(key) orelse return null) {
        .dedicated => |index| {
            const entry = &cache.entries[index];
            return if (matches(entry, key)) entry.view() else null;
        },
        .set => |set| {
            for (cache.setEntries(set)) |*entry| {
                if (matches(entry, key)) {
                    return entry.view();
                }
            }

            return null;
        },
    }
}

/// Copies the borrowed HarfBuzz result. Example: `cache.remember(.{ .text = text }, shaped);`
pub fn remember(cache: *Cache, key: Key, shaped: ShapedRun) void {
    if (shaped.glyphs.len > Entry.max_glyphs) {
        return;
    }

    const entry = switch (slotFor(key) orelse return) {
        .dedicated => |index| &cache.entries[index],
        .set => |set| cache.victim(set, key),
    };

    @memcpy(entry.text[0..key.text.len], key.text);
    @memcpy(entry.glyphs[0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(entry.positions[0..shaped.positions.len], shaped.positions);
    entry.font = shaped.font;
    entry.preferred = key.face;
    entry.columns = shaped.columns;
    entry.len = @intCast(key.text.len);
    entry.count = @intCast(shaped.glyphs.len);
}

// Reuses the way already holding `key`, then an empty way, then the set's
// round-robin victim so four colliding labels share the set stably.
fn victim(cache: *Cache, set: usize, key: Key) *Entry {
    const candidates = cache.setEntries(set);
    for (candidates) |*entry| {
        if (matches(entry, key)) {
            return entry;
        }
    }

    for (candidates) |*entry| {
        if (entry.len == 0) {
            return entry;
        }
    }

    const way = cache.victims[set] % ways;
    cache.victims[set] = (cache.victims[set] + 1) % ways;
    return &candidates[way];
}

test "colliding labels share a set instead of evicting one another" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    const set = slotFor(.{ .text = "1 agents", .face = .sans }).?.set;
    var found: [5][]const u8 = undefined;
    var count: usize = 0;
    var storage: [5][8]u8 = undefined;
    var attempt: u32 = 0;
    while (count < found.len) : (attempt += 1) {
        const text = std.fmt.bufPrint(&storage[count], "x{d}", .{attempt}) catch unreachable;
        if (slotFor(.{ .text = text, .face = .sans }).?.set == set) {
            found[count] = text;
            count += 1;
        }
    }

    const empty: ShapedRun = .{ .glyphs = &.{}, .positions = &.{}, .font = .sans, .columns = 0 };
    for (found[0..4]) |text| {
        cache.remember(.{ .text = text, .face = .sans }, empty);
    }

    for (found[0..4]) |text| {
        try std.testing.expect(cache.find(.{ .text = text, .face = .sans }) != null);
    }

    cache.remember(.{ .text = found[4], .face = .sans }, empty);
    try std.testing.expect(cache.find(.{ .text = found[4], .face = .sans }) != null);
    try std.testing.expect(cache.find(.{ .text = found[0], .face = .sans }) == null);
    try std.testing.expect(cache.find(.{ .text = found[1], .face = .sans }) != null);
}

test "a repeated run reuses its own way and dedicated ASCII faces and long runs stay apart" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    const shaped: ShapedRun = .{ .font = .sans, .columns = 1, .glyphs = &.{}, .positions = &.{} };
    cache.remember(.{ .text = "alpha", .face = .sans }, shaped);
    cache.remember(.{ .text = "beta", .face = .sans }, shaped);
    try std.testing.expect(cache.find(.{ .text = "alpha", .face = .sans }) != null);
    try std.testing.expect(cache.find(.{ .text = "beta", .face = .sans }) != null);
    try std.testing.expect(cache.find(.{ .text = "alpha", .face = .primary }) == null);

    cache.remember(.{ .text = "alpha", .face = .sans }, shaped);
    try std.testing.expect(cache.find(.{ .text = "beta", .face = .sans }) != null);
    cache.remember(.{ .text = "a", .face = .primary }, shaped);
    try std.testing.expect(cache.find(.{ .text = "a", .face = .primary }) != null);
    try std.testing.expect(cache.find(.{ .text = "a", .face = .sans }) == null);
    try std.testing.expect(cache.find(.{ .text = "x" ** (Entry.max_bytes + 1), .face = .sans }) == null);
    try std.testing.expectEqual(@as(usize, 384), capacity);
}
