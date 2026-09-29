//! One RGBA8 page of the sprites the GPU samples beside the alpha glyph
//! atlas, in equal slots. A slot holds one cell per `SpriteSize` side by
//! side, each that size's logical side at the chrome ratio, so a favicon is
//! drawn one texel per pixel in every view. The provider marks from the
//! embedded sheet fill the first slots at construction, at `large` only;
//! favicons take the rest as they land, at most `max_favicons`. Texels are
//! premultiplied so linear sampling never fringes. `version` advances with
//! every slot written, so the backend re-uploads the page once per landed
//! favicon and never on a warm frame. The page is square and its bytes
//! follow the cells: 306 KiB at a ratio of 1, 736 KiB at 1.53 (a 23 pt
//! font), 2.8 MiB at 3.07 (the same on a 2x display) and 6.9 MiB at the
//! `max_cell` bound.
const std = @import("std");
const core = @import("telar-core");
const assets = @import("assets");
const Sprite = @import("Sprite.zig");
const SpriteSize = @import("SpriteSize.zig").SpriteSize;
const imaging = @import("imaging");
const data = @import("model");
const ImageView = imaging.ImageView;
const resize = imaging.resize;
const SpritePage = @This();

/// One cell side per sprite size, in texels; the favicon job carries it.
pub const Cells = [SpriteSize.count]u16;
/// One image per sprite size; a null size stays transparent.
pub const Images = [SpriteSize.count]?ImageView;

pub const min_cell: u16 = 8;
/// The rail at a chrome ratio of 4.8: a 36 pt font on a 2x display.
pub const max_cell: u16 = 96;
pub const max_favicons: u16 = 64;
/// Slots on each row of the page and rows of slots: a slot is about 2.6
/// times as wide as it is tall, so this grid keeps the page nearly square.
pub const slot_columns: u32 = 5;
pub const slot_rows: u32 = 14;
const provider_slot: u32 = 64;
const providers = [_]core.AgentProvider{ .claude, .codex, .pi, .cursor, .opencode };
/// Slots the provider marks take before the first favicon.
pub const provider_mark_count: u16 = providers.len;

comptime {
    std.debug.assert(assets.provider_symbols_rgba.len == providers.len * provider_slot * provider_slot * 4);
    std.debug.assert(slot_columns * slot_rows >= providers.len + max_favicons);
}

allocator: std.mem.Allocator,
pixels: []u8,
cells: Cells,
/// Texels on each side of the page.
side: u32,
count: u16 = 0,
version: u32 = 1,
provider_marks: [providers.len]Sprite = undefined,

/// Allocates the page for one chrome ratio and resizes the provider sheet
/// into its first slots.
/// Example: `var page = try SpritePage.init(allocator, chrome.ratio);`
pub fn init(allocator: std.mem.Allocator, ratio: f32) !SpritePage {
    const cells = cellsFor(ratio);
    const side = @max(slot_columns * slotWidth(cells), slot_rows * @as(u32, cells[@intFromEnum(SpriteSize.large)]));
    const pixels = try allocator.alloc(u8, @as(usize, side) * side * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    var page: SpritePage = .{
        .allocator = allocator,
        .pixels = pixels,
        .cells = cells,
        .side = side,
    };

    const large = page.cell(.large);
    const scratch = try allocator.alloc(u8, @as(usize, large) * large * 4);
    defer allocator.free(scratch);
    for (providers, 0..) |_, index| {
        const slot: ImageView = .{ .pixels = assets.provider_symbols_rgba, .stride = providers.len * provider_slot * 4, .x = @intCast(index * provider_slot), .width = provider_slot, .height = provider_slot };
        resize.square(slot, scratch, large);
        var images: Images = @splat(null);
        images[@intFromEnum(SpriteSize.large)] = .{ .pixels = scratch, .stride = large * 4, .width = large, .height = large };
        page.provider_marks[index] = .{
            .index = try page.add(images),
            .size = .large,
        };
    }

    return page;
}

pub fn deinit(self: *SpritePage) void {
    self.allocator.free(self.pixels);
    self.* = undefined;
}

/// The cell side of every sprite size for one chrome ratio, the device
/// pixels per logical chrome pixel that follow the display scale and the
/// font size: whole texels inside the bounds, so a view whose side is
/// rounded the same way samples one texel per pixel.
/// Example: `const cells = SpritePage.cellsFor(chrome.ratio);`
pub fn cellsFor(ratio: f32) Cells {
    var cells: Cells = undefined;
    for (SpriteSize.all, &cells) |size, *side| {
        const wanted = @round(size.logical() * ratio);
        side.* = if (wanted >= min_cell) @intFromFloat(@min(max_cell, wanted)) else min_cell;
    }

    return cells;
}

/// The cell side of one sprite size, in texels.
/// Example: `const side = page.cell(.medium);`
pub fn cell(self: *const SpritePage, size: SpriteSize) u32 {
    return self.cells[@intFromEnum(size)];
}

/// Slots the page can hold in total.
/// Example: `try std.testing.expect(page.capacity() >= 69);`
pub fn capacity(_: *const SpritePage) u16 {
    return slot_columns * slot_rows;
}

/// Favicon slots still free: the sheet keeps `max_favicons` at most.
/// Example: `if (page.faviconRoom() == 0) keepGlyph();`
pub fn faviconRoom(self: *const SpritePage) u16 {
    const used = self.count -| @as(u16, providers.len);
    return @min(max_favicons - @min(max_favicons, used), self.capacity() - self.count);
}

/// The embedded mark of a built-in provider; custom providers have none.
/// Example: `if (page.providerMark(agent.provider)) |mark| try canvas.spriteAt(box, mark);`
pub fn providerMark(self: *const SpritePage, provider: core.AgentProvider) ?Sprite {
    for (providers, self.provider_marks) |known, sprite| {
        if (known == provider) {
            return sprite;
        }
    }

    return null;
}

/// Copies one straight-alpha favicon per sprite size, each `cell(size)`
/// a side, into the next free slot and returns the slot.
/// Example: `const slot = try page.addFavicon(images);`
pub fn addFavicon(self: *SpritePage, images: Images) !u16 {
    if (self.faviconRoom() == 0) {
        return error.SheetFull;
    }

    for (images) |image| {
        if (image == null) {
            return error.SpriteSizeMismatch;
        }
    }

    return self.add(images);
}

/// Texture coordinates of a sprite's cell: u0, v0, u1, v1 in the page.
/// Example: `const uv = page.uv(sprite);`
pub fn uv(self: *const SpritePage, sprite: Sprite) [4]f32 {
    const corner = self.origin(sprite.index, sprite.size);
    const left: f32 = @floatFromInt(corner[0]);
    const top: f32 = @floatFromInt(corner[1]);
    const side: f32 = @floatFromInt(self.cell(sprite.size));
    const extent: f32 = @floatFromInt(self.side);
    return .{ left / extent, top / extent, (left + side) / extent, (top + side) / extent };
}

// The top-left texel of one size's cell in one slot: the cells of a slot
// sit side by side from the smallest.
fn origin(self: *const SpritePage, slot: u16, size: SpriteSize) [2]u32 {
    var left = (slot % slot_columns) * slotWidth(self.cells);
    for (SpriteSize.all[0..@intFromEnum(size)]) |smaller| {
        left += self.cell(smaller);
    }

    return .{ left, (slot / slot_columns) * self.cell(.large) };
}

fn slotWidth(cells: Cells) u32 {
    var width: u32 = 0;
    for (cells) |side| {
        width += @as(u32, side);
    }

    return width;
}

fn add(self: *SpritePage, images: Images) !u16 {
    for (SpriteSize.all, images) |size, entry| {
        const image = entry orelse continue;
        if (image.width != self.cell(size) or image.height != self.cell(size)) {
            return error.SpriteSizeMismatch;
        }
    }

    if (self.count >= self.capacity()) {
        return error.SheetFull;
    }

    const slot = self.count;
    for (SpriteSize.all, images) |size, entry| {
        const image = entry orelse continue;
        const corner = self.origin(slot, size);
        const side = self.cell(size);
        for (0..side) |row| {
            const destination = self.pixels[((corner[1] + row) * self.side + corner[0]) * 4 ..][0 .. side * 4];
            for (0..side) |column| {
                destination[column * 4 ..][0..4].* = imaging.premultiply.pixel(image.pixel(@intCast(column), @intCast(row)));
            }
        }
    }

    self.count += 1;
    self.version +%= 1;
    return slot;
}

test "the page holds the provider marks then at most 64 favicons and premultiplies" {
    var page = try SpritePage.init(std.testing.allocator, 1);
    defer page.deinit();
    try std.testing.expectEqualSlices(u16, &.{ 14, 18, 20 }, &page.cells);
    try std.testing.expectEqual(provider_mark_count, page.count);
    try std.testing.expectEqual(@as(u16, 70), page.capacity());
    // Five slots of 52 texels across, fourteen rows of 20 down.
    try std.testing.expectEqual(@as(u32, 280), page.side);
    try std.testing.expectEqual(@as(usize, 280 * 280 * 4), page.pixels.len);
    try std.testing.expectEqual(max_favicons, page.faviconRoom());
    try std.testing.expect(page.providerMark(.claude) != null);
    try std.testing.expect(page.providerMark(.pi).?.index == 2);
    try std.testing.expect(page.providerMark(.cursor).?.index == 3);
    try std.testing.expect(page.providerMark(.opencode).?.index == 4);
    try std.testing.expect(page.providerMark(.opencode).?.size == .large);
    try std.testing.expect(page.providerMark(.unknown) == null);
    try std.testing.expect(page.providerMark(@enumFromInt(9)) == null);

    const half = [_]u8{ 200, 100, 0, 128 } ** (20 * 20);
    var images: Images = undefined;
    for (SpriteSize.all, &images) |size, *image| {
        image.* = .{ .pixels = &half, .stride = page.cell(size) * 4, .width = page.cell(size), .height = page.cell(size) };
    }

    const version = page.version;
    const first = try page.addFavicon(images);
    try std.testing.expectEqual(provider_mark_count, first);
    try std.testing.expectEqual(version + 1, page.version);
    const extent: f32 = @floatFromInt(page.side);
    var right_edge: f32 = 0;
    for (SpriteSize.all) |size| {
        const cell_uv = page.uv(.{ .index = first, .size = size });
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(page.cell(size))), (cell_uv[2] - cell_uv[0]) * extent, 0.001);
        try std.testing.expect(cell_uv[0] >= right_edge);
        right_edge = cell_uv[2];
        const texel = page.pixels[(@as(usize, @intFromFloat(cell_uv[1] * extent)) * page.side + @as(usize, @intFromFloat(cell_uv[0] * extent))) * 4 ..][0..4];
        try std.testing.expectEqualSlices(u8, &.{ 100, 50, 0, 128 }, texel);
    }

    var missing = images;
    missing[@intFromEnum(SpriteSize.medium)] = null;
    try std.testing.expectError(error.SpriteSizeMismatch, page.addFavicon(missing));
    try std.testing.expectError(error.SpriteSizeMismatch, page.addFavicon(.{ images[1], images[0], images[2] }));
    for (1..max_favicons) |_| {
        _ = try page.addFavicon(images);
    }

    try std.testing.expectEqual(@as(u16, 0), page.faviconRoom());
    try std.testing.expectError(error.SheetFull, page.addFavicon(images));
}

test "cells follow the chrome ratio inside the bounds" {
    try std.testing.expectEqualSlices(u16, &.{ 14, 18, 20 }, &cellsFor(1));
    try std.testing.expectEqualSlices(u16, &.{ 28, 36, 40 }, &cellsFor(2));
    // A 23 pt font against the 15 pt reference, on a 1x and a 2x display.
    try std.testing.expectEqualSlices(u16, &.{ 21, 28, 31 }, &cellsFor(23.0 / 15.0));
    try std.testing.expectEqualSlices(u16, &.{ 43, 55, 61 }, &cellsFor(2 * 23.0 / 15.0));
    try std.testing.expectEqualSlices(u16, &.{ 67, 86, max_cell }, &cellsFor(4.8));
    try std.testing.expectEqualSlices(u16, &.{ max_cell, max_cell, max_cell }, &cellsFor(std.math.inf(f32)));
    try std.testing.expectEqualSlices(u16, &.{ min_cell, min_cell, min_cell }, &cellsFor(0.1));
    try std.testing.expectEqualSlices(u16, &.{ min_cell, min_cell, min_cell }, &cellsFor(std.math.nan(f32)));

    // Page bytes at the reported sizes: 1x, a 23 pt font at 1x and 2x, the bound.
    for ([_]f32{ 1, 23.0 / 15.0, 2 * 23.0 / 15.0, 4.8 }, [_]u32{ 280, 434, 854, 1344 }) |ratio, side| {
        var page = try SpritePage.init(std.testing.allocator, ratio);
        defer page.deinit();
        try std.testing.expectEqual(side, page.side);
        try std.testing.expectEqual(max_favicons, page.faviconRoom());
    }
}

test "provider symbols preserve alpha and OpenAI, Cursor and OpenCode are tintable white masks" {
    // Below and above the 64 texel artwork, so both filters are covered.
    for ([_]f32{ 1.6, 4.8 }) |ratio| {
        try expectProviderSymbols(ratio);
    }
}

fn expectProviderSymbols(ratio: f32) !void {
    var page = try SpritePage.init(std.testing.allocator, ratio);
    defer page.deinit();
    const side = page.cell(.large);
    const extent: f32 = @floatFromInt(page.side);
    for (providers) |provider| {
        const cell_uv = page.uv(page.providerMark(provider).?);
        const left: usize = @intFromFloat(cell_uv[0] * extent);
        const top: usize = @intFromFloat(cell_uv[1] * extent);
        var visible: usize = 0;
        var transparent: usize = 0;
        for (0..side) |y| {
            for (0..side) |x| {
                const rgba = page.pixels[((top + y) * page.side + left + x) * 4 ..][0..4];
                if (data.icons.providerMarkFollowsTheme(provider)) {
                    try std.testing.expectEqual(rgba[3], rgba[0]);
                    try std.testing.expectEqual(rgba[3], rgba[1]);
                    try std.testing.expectEqual(rgba[3], rgba[2]);
                }

                visible += @intFromBool(rgba[3] > 0);
                transparent += @intFromBool(rgba[3] == 0);
            }
        }

        try std.testing.expect(visible > 0 and transparent > 0);
    }
}
