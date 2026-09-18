//! Lazily allocated by composer preparation. Two copies of the maximum editor
//! text admit its paragraph and wrapped lines; native lookups never allocate.
const std = @import("std");
const freetype = @import("freetype");
const Entry = @import("EditorShapingEntry.zig");
const Key = @import("ShapingKey.zig");
const ShapedRun = @import("ShapedRun.zig");
const Cache = @This();

const capacity = 16 * 1024;
text: [capacity]u8 = undefined,
glyphs: [capacity]freetype.c.hb_glyph_info_t = undefined,
positions: [capacity]freetype.c.hb_glyph_position_t = undefined,
entries: [128]Entry = undefined,
text_len: u16 = 0,
glyph_count: u16 = 0,
count: u8 = 0,

/// Returned spans remain valid until the next insertion clears the arena.
/// Example: `if (cache.find(key)) |shaped| return shaped;`
pub fn find(cache: *const Cache, key: Key) ?ShapedRun {
    if (key.text.len <= @import("ShapingEntry.zig").max_bytes) {
        return null;
    }

    const hash = fingerprint(key);
    for (cache.entries[0..cache.count]) |entry| {
        if (entry.hash != hash or entry.text_len != key.text.len or entry.pixel_height != key.pixel_height or entry.preferred != key.face) {
            continue;
        }

        if (std.mem.eql(u8, cache.text[entry.text_start..][0..entry.text_len], key.text)) {
            return .{ .font = entry.font, .columns = entry.columns, .rtl = entry.rtl, .glyphs = cache.glyphs[entry.glyph_start..][0..entry.glyph_count], .positions = cache.positions[entry.glyph_start..][0..entry.glyph_count] };
        }
    }

    return null;
}

/// Retires borrowed results without releasing the fixed storage budget.
/// Example: `cache.clear();`
pub fn clear(cache: *Cache) void {
    cache.text_len = 0;
    cache.glyph_count = 0;
    cache.count = 0;
}

/// Owns long runs without retaining caller buffers or growing the budget.
/// Example: `cache.remember(key, shaped);`
pub fn remember(cache: *Cache, key: Key, shaped: ShapedRun) void {
    if (key.text.len <= @import("ShapingEntry.zig").max_bytes or key.text.len > capacity or shaped.glyphs.len > capacity) {
        return;
    }

    if (cache.count == cache.entries.len or key.text.len > capacity - cache.text_len or shaped.glyphs.len > capacity - cache.glyph_count) {
        cache.clear();
    }

    @memcpy(cache.text[cache.text_len..][0..key.text.len], key.text);
    @memcpy(cache.glyphs[cache.glyph_count..][0..shaped.glyphs.len], shaped.glyphs);
    @memcpy(cache.positions[cache.glyph_count..][0..shaped.positions.len], shaped.positions);
    cache.entries[cache.count] = .{
        .hash = fingerprint(key),
        .text_start = cache.text_len,
        .text_len = @intCast(key.text.len),
        .glyph_start = cache.glyph_count,
        .glyph_count = @intCast(shaped.glyphs.len),
        .pixel_height = key.pixel_height,
        .preferred = key.face,
        .font = shaped.font,
        .columns = shaped.columns,
        .rtl = shaped.rtl,
    };
    cache.text_len += @intCast(key.text.len);
    cache.glyph_count += @intCast(shaped.glyphs.len);
    cache.count += 1;
}

fn fingerprint(key: Key) u64 {
    return std.hash.Wyhash.hash(@as(u64, @intFromEnum(key.face)) | (@as(u64, key.pixel_height) << 8), key.text);
}

test "long editor runs own text and glyphs and evict within a fixed budget" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var text: [100]u8 = @splat('a');
    var glyphs: [1]freetype.c.hb_glyph_info_t = .{std.mem.zeroes(freetype.c.hb_glyph_info_t)};
    var positions: [1]freetype.c.hb_glyph_position_t = .{std.mem.zeroes(freetype.c.hb_glyph_position_t)};
    glyphs[0].codepoint = 17;
    positions[0].x_advance = 64;
    cache.remember(.{ .text = &text, .face = .sans, .pixel_height = 16 }, .{ .font = .sans, .columns = 100, .glyphs = &glyphs, .positions = &positions });
    glyphs[0].codepoint = 99;
    positions[0].x_advance = 1;
    text[0] = 'b';
    const key: Key = .{ .text = "a" ** 100, .face = .sans, .pixel_height = 16 };
    const owned = cache.find(key).?;
    try std.testing.expectEqual(@as(u32, 17), owned.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(i32, 64), owned.positions[0].x_advance);
    try std.testing.expect(cache.find(.{ .text = key.text, .face = .sans, .pixel_height = 32 }) == null);
    for (0..150) |index| {
        _ = try std.fmt.bufPrint(text[0..8], "{d:0>8}", .{index});
        cache.remember(.{ .text = &text, .face = .sans, .pixel_height = 16 }, .{ .font = .sans, .columns = 100, .glyphs = &glyphs, .positions = &positions });
    }

    try std.testing.expect(cache.find(key) == null);
    try std.testing.expect(cache.text_len <= capacity and cache.glyph_count <= capacity and cache.count <= cache.entries.len);
    try std.testing.expect(@sizeOf(Cache) <= 665 * 1024);
}
