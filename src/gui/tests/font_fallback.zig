//! System font fallback: graphemes no embedded face covers are looked up
//! once through the native port, loaded into a bounded pool and painted
//! fitted to the cell; misses and a full pool keep the replacement glyph.
const std = @import("std");
const builtin = @import("builtin");
const assets = @import("assets");
const Atlas = @import("../text/GlyphAtlas.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FallbackPool = @import("../text/FallbackPool.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("../text/TextRun.zig");
const Id = @import("../text/font_id.zig").Id;

/// U+23F5, the arrow Claude Code prints in `⏵⏵ auto mode on`; in neither
/// JetBrains Mono nor Symbols Nerd Font Mono.
const arrow = "\u{23f5}";

fn discoveringAtlas() !Atlas {
    return Atlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16, .io = std.testing.io });
}

fn cellRun(text: []const u8) TextRun {
    return .{ .text = text, .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
}

/// Graphemes no embedded face covers, tried in order until this host has an
/// installed face for one: the Mac must resolve U+23F5; a Linux machine with
/// only DejaVu Sans Mono resolves U+2699.
const uncovered = [_][]const u8{ arrow, "\u{2699}", "\u{2b95}" };

test "a grapheme no embedded face covers resolves to a discovered installed face fitted to the cell" {
    var atlas = try discoveringAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var arrow_value: []const u8 = arrow;
    for (uncovered, 1..) |candidate, lookups| {
        try std.testing.expect(!atlas.fonts.primary.covers(candidate));
        try std.testing.expect(!atlas.fonts.symbols.covers(candidate));
        try std.testing.expectEqual(Id.primary, atlas.fonts.source(candidate, .primary));
        var text_buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "{s}{s} auto mode on", .{ candidate, candidate });
        list.clear();
        _ = try atlas.place(cellRun(text), &list);
        try std.testing.expectEqual(lookups, atlas.fonts.lookups);
        arrow_value = candidate;
        if (atlas.fonts.pool.count == 1) {
            break;
        }

        if (builtin.os.tag == .macos) {
            return error.NoInstalledFaceCoversTheArrow;
        }
    } else {
        return error.SkipZigTest;
    }

    const id = atlas.fonts.source(arrow_value, .primary);
    try std.testing.expectEqual(@as(?u3, 0), id.fallbackSlot());
    try std.testing.expect(id.fitted());
    try std.testing.expect(atlas.fonts.get(id).covers(arrow_value));
    try std.testing.expect(atlas.fonts.get(id).monochrome());
    const shaped = atlas.shaping_cache.find(.{ .text = arrow_value, .face = .primary, .pixel_height = 16 }).?;
    try std.testing.expectEqual(id, shaped.font);
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
    try std.testing.expect(shaped.glyphs[0].codepoint != 0);
    const cell: f32 = @floatFromInt(try atlas.cellWidth(16));
    const first = list.items()[0];
    try std.testing.expect(first.width > 0 and first.width <= cell);
    try std.testing.expect(first.height > 0 and first.height <= @as(f32, @floatFromInt(try atlas.lineHeight(16))));
    try std.testing.expect(list.items()[1].x >= cell);
    const lookups = atlas.fonts.lookups;
    list.clear();
    _ = try atlas.place(cellRun(arrow_value), &list);
    try std.testing.expectEqual(lookups, atlas.fonts.lookups);
}

var missing_calls: usize = 0;

fn missingLookup(text: [*:0]const u8, match: *FontMatch) callconv(.c) c_int {
    _ = text;
    _ = match;
    missing_calls += 1;
    return -1;
}

test "a grapheme no installed face covers is looked up once and keeps the replacement glyph" {
    var atlas = try discoveringAtlas();
    defer atlas.deinit();
    atlas.fonts.lookup = missingLookup;
    missing_calls = 0;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    for (0..3) |_| {
        list.clear();
        _ = try atlas.place(cellRun(arrow), &list);
        _ = try atlas.measure(cellRun(arrow ++ " on"));
        atlas.shaping_cache.clear();
    }

    try std.testing.expectEqual(@as(usize, 1), missing_calls);
    try std.testing.expectEqual(@as(usize, 1), atlas.fonts.lookups);
    try std.testing.expectEqual(@as(u8, 0), atlas.fonts.pool.count);
    try std.testing.expect(atlas.fonts.misses.contains(arrow));
    try std.testing.expectEqual(Id.primary, atlas.fonts.source(arrow, .primary));
    _ = try atlas.place(cellRun(arrow), &list);
    const shaped = atlas.shaping_cache.find(.{ .text = arrow, .face = .primary, .pixel_height = 16 }).?;
    try std.testing.expectEqual(Id.primary, shaped.font);
    try std.testing.expectEqual(@as(u32, 0), shaped.glyphs[0].codepoint);
}

/// Latin graphemes IBM Plex Sans covers and neither terminal face does, so a
/// copy of Plex under a distinct path stands in for a distinct installed face.
const plex_only = [_][:0]const u8{ "\u{132}", "\u{133}", "\u{1cf}", "\u{1d1}", "\u{1d3}", "\u{1d5}", "\u{1d7}", "\u{1d9}", "\u{1db}" };

var copies_dir: [std.fs.max_path_bytes]u8 = undefined;
var copies_dir_len: usize = 0;

fn copyName(text: []const u8, buffer: []u8) ![]const u8 {
    const codepoint = try std.unicode.utf8Decode(text[0..try std.unicode.utf8ByteSequenceLength(text[0])]);
    return std.fmt.bufPrint(buffer, "{x}.ttf", .{codepoint});
}

fn copiedLookup(text: [*:0]const u8, match: *FontMatch) callconv(.c) c_int {
    var name: [32]u8 = undefined;
    const file = copyName(std.mem.span(text), &name) catch return -1;
    match.* = .{};
    _ = std.fmt.bufPrint(&match.path, "{s}/{s}", .{ copies_dir[0..copies_dir_len], file }) catch return -1;
    return 0;
}

test "the pool holds eight discovered faces refuses the ninth and evicts nothing" {
    const FallbackFace = @import("../text/FallbackFace.zig");
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    copies_dir_len = try temp.dir.realPath(io, &copies_dir);
    for (plex_only) |text| {
        var name: [32]u8 = undefined;
        try temp.dir.writeFile(io, .{ .sub_path = try copyName(text, &name), .data = assets.plex_sans });
    }

    var atlas = try discoveringAtlas();
    defer atlas.deinit();
    var matches: [plex_only.len]FontMatch = undefined;
    for (plex_only, &matches, 0..) |text, *match, index| {
        try std.testing.expectEqual(0, copiedLookup(text.ptr, match));
        var face = try FallbackFace.init(std.testing.allocator, atlas.fonts.context, match.*);
        const slot = atlas.fonts.pool.add(face);
        if (index < FallbackPool.capacity) {
            try std.testing.expectEqual(@as(?u3, @intCast(index)), slot);
        } else {
            try std.testing.expectEqual(@as(?u3, null), slot);
            face.deinit(std.testing.allocator);
        }
    }

    try std.testing.expect(atlas.fonts.pool.full());
    try std.testing.expectEqual(@as(u8, FallbackPool.capacity), atlas.fonts.pool.count);
    for (matches[0..FallbackPool.capacity], 0..) |match, slot| {
        try std.testing.expectEqual(@as(?u3, @intCast(slot)), atlas.fonts.pool.find(match));
    }

    try std.testing.expectEqual(@as(?u3, null), atlas.fonts.pool.find(matches[FallbackPool.capacity]));
    try std.testing.expectEqual(Id.fallback_0, atlas.fonts.source(plex_only[0], .primary));

    // A grapheme none of the eight covers is refused without asking the port.
    atlas.fonts.lookup = missingLookup;
    missing_calls = 0;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try atlas.place(cellRun(arrow), &list);
    try std.testing.expectEqual(@as(usize, 0), missing_calls);
    try std.testing.expectEqual(@as(usize, 0), atlas.fonts.lookups);
    try std.testing.expect(atlas.fonts.misses.contains(arrow));
    try std.testing.expectEqual(Id.primary, atlas.fonts.source(arrow, .primary));
    const shaped = atlas.shaping_cache.find(.{ .text = arrow, .face = .primary, .pixel_height = 16 }).?;
    try std.testing.expectEqual(Id.primary, shaped.font);
    try std.testing.expectEqual(@as(u32, 0), shaped.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(u8, FallbackPool.capacity), atlas.fonts.pool.count);
    for (matches[0..FallbackPool.capacity], 0..) |match, slot| {
        try std.testing.expectEqual(@as(?u3, @intCast(slot)), atlas.fonts.pool.find(match));
    }
}

test "one installed file serves every grapheme it covers through one pool slot" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    copies_dir_len = try temp.dir.realPath(io, &copies_dir);
    var name: [32]u8 = undefined;
    try temp.dir.writeFile(io, .{ .sub_path = try copyName(plex_only[0], &name), .data = assets.plex_sans });
    var atlas = try discoveringAtlas();
    defer atlas.deinit();
    atlas.fonts.lookup = copiedLookup;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try atlas.place(cellRun(plex_only[0] ++ plex_only[1]), &list);
    try std.testing.expectEqual(@as(u8, 1), atlas.fonts.pool.count);
    try std.testing.expectEqual(@as(usize, 1), atlas.fonts.lookups);
    try std.testing.expectEqual(Id.fallback_0, atlas.fonts.source(plex_only[1], .primary));
    try std.testing.expect(!atlas.fonts.misses.contains(plex_only[1]));
}

test "an atlas without an io never looks for installed faces" {
    var atlas = try Atlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    atlas.fonts.lookup = missingLookup;
    missing_calls = 0;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try atlas.place(cellRun(arrow), &list);
    try std.testing.expectEqual(@as(usize, 0), missing_calls);
    try std.testing.expectEqual(@as(usize, 0), atlas.fonts.lookups);
}

test "the native fallback port reports a readable monochrome file or none" {
    const FontSet = @import("../text/FontSet.zig");
    var match: FontMatch = .{};
    const lookup: FontSet.Lookup = FontSet.native_lookup;
    if (lookup(arrow, &match) == 0) {
        const path = std.mem.sliceTo(&match.path, 0);
        try std.testing.expect(path.len > 0);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(@import("../text/FontSource.zig").max_bytes));
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(bytes.len > 0);
    }

    try std.testing.expect(lookup("", &match) != 0);
}
