//! Bounded, owned shaping results for one font set at every height it
//! paints. The first height of each primary ASCII character has a dedicated
//! slot; other heights and runs hash into a four-way set, so up
//! to four labels sharing a hash stay cached together instead of evicting
//! one another every frame. A fifth replaces the set's oldest. Long runs
//! bypass the cache. Entries include the requested and the resolved face
//! identity and the pixel height; no paint or GPU state is held.
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

pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
    allocator.free(self.entries);
}

/// Invalidates font-dependent results. Example: `cache.clear();`
pub fn clear(self: *Cache) void {
    for (self.entries) |*entry| {
        entry.len = 0;
    }

    self.victims = @splat(0);
}

const Slot = union(enum) {
    dedicated: usize,
    set: usize,
};

fn slotFor(self: *const Cache, key: Key) ?Slot {
    const text = key.text;
    if (text.len == 0 or text.len > Entry.max_bytes) {
        return null;
    }

    if (text.len == 1 and text[0] < ascii_capacity and key.face == .primary) {
        const entry = &self.entries[text[0]];
        if (entry.len == 0 or entry.pixel_height == key.pixel_height) {
            return .{ .dedicated = text[0] };
        }
    }

    return .{ .set = std.hash.Wyhash.hash(seed(key), text) % sets };
}

// The face and the height salt the hash so one word at three chrome sizes
// spreads over the sets instead of contending for one.
fn seed(key: Key) u64 {
    return @as(u64, @intFromEnum(key.face)) | (@as(u64, key.pixel_height) << 8);
}

fn matches(entry: *const Entry, key: Key) bool {
    return entry.len == key.text.len and entry.preferred == key.face and entry.pixel_height == key.pixel_height and std.mem.eql(u8, entry.text[0..entry.len], key.text);
}

fn setEntries(self: *Cache, set: usize) []Entry {
    const start = ascii_capacity + set * ways;
    return self.entries[start .. start + ways];
}

/// Borrows until the next insertion or clear.
/// Example: `const hit = cache.find(.{ .text = text, .face = .sans });`
pub fn find(self: *Cache, key: Key) ?ShapedRun {
    switch (self.slotFor(key) orelse return null) {
        .dedicated => |index| {
            const entry = &self.entries[index];
            return if (matches(entry, key)) entry.view() else null;
        },
        .set => |set| {
            for (self.setEntries(set)) |*entry| {
                if (matches(entry, key)) {
                    return entry.view();
                }
            }

            return null;
        },
    }
}

/// Copies the borrowed HarfBuzz result. Example: `cache.remember(.{ .text = text }, shaped);`
pub fn remember(self: *Cache, key: Key, shaped: ShapedRun) void {
    if (shaped.glyphs.len > Entry.max_glyphs) {
        return;
    }

    const entry = switch (self.slotFor(key) orelse return) {
        .dedicated => |index| &self.entries[index],
        .set => |set| self.victim(set, key),
    };

    @memcpy(entry.text[0..key.text.len], key.text);
    @memcpy(entry.glyphs[0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(entry.positions[0..shaped.positions.len], shaped.positions);
    entry.font = shaped.font;
    entry.preferred = key.face;
    entry.pixel_height = key.pixel_height;
    entry.columns = shaped.columns;
    entry.rtl = shaped.rtl;
    entry.len = @intCast(key.text.len);
    entry.count = @intCast(shaped.glyphs.len);
}

// Reuses the way already holding `key`, then an empty way, then the set's
// round-robin victim so four colliding labels share the set stably.
fn victim(self: *Cache, set: usize, key: Key) *Entry {
    const candidates = self.setEntries(set);
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

    const way = self.victims[set] % ways;
    self.victims[set] = (self.victims[set] + 1) % ways;
    return &candidates[way];
}
