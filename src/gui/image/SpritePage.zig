//! One RGBA8 page of equal square cells the GPU samples beside the alpha
//! glyph atlas. The three provider marks from the embedded sheet fill the
//! first cells at construction; favicons take the rest as they land, at
//! most `max_favicons`. Texels are premultiplied so linear sampling never
//! fringes. `version` advances with every cell written, so the backend
//! re-uploads the page once per landed image and never on a warm frame.
const std = @import("std");
const core = @import("telar-core");
const assets = @import("assets");
const Sprite = @import("Sprite.zig");
const ImageView = @import("ImageView.zig");
const box_filter = @import("box_filter.zig");
const SpritePage = @This();

/// One page, square, in texels.
pub const side: u32 = 512;
/// The provider mark of the card is this many logical pixels; a cell is
/// that size at the display scale so the mark samples one texel per pixel.
pub const mark_logical: f32 = 16;
pub const min_cell: u32 = 8;
pub const max_cell: u32 = 48;
pub const max_favicons: u16 = 64;
const provider_slot: u32 = 256;
const providers = [_]core.AgentProvider{ .claude, .codex, .pi };

comptime {
    std.debug.assert(assets.provider_marks_rgba.len == providers.len * provider_slot * provider_slot * 4);
    std.debug.assert((side / max_cell) * (side / max_cell) >= providers.len + max_favicons);
}

allocator: std.mem.Allocator,
pixels: []u8,
cell: u32,
columns: u32,
count: u16 = 0,
version: u32 = 1,
provider_marks: [providers.len]Sprite = undefined,

/// Allocates the page and box-filters the provider sheet into its first
/// cells. `cell` comes from `cellFor`.
/// Example: `var page = try SpritePage.init(allocator, SpritePage.cellFor(2));`
pub fn init(allocator: std.mem.Allocator, cell: u32) !SpritePage {
    if (cell < min_cell or cell > max_cell) {
        return error.InvalidSpriteCell;
    }

    const pixels = try allocator.alloc(u8, @as(usize, side) * side * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    var page: SpritePage = .{ .allocator = allocator, .pixels = pixels, .cell = cell, .columns = side / cell };
    const scratch = try allocator.alloc(u8, @as(usize, cell) * cell * 4);
    defer allocator.free(scratch);
    for (providers, 0..) |_, index| {
        const slot: ImageView = .{ .pixels = assets.provider_marks_rgba, .stride = providers.len * provider_slot * 4, .x = @intCast(index * provider_slot), .width = provider_slot, .height = provider_slot };
        box_filter.resample(slot, scratch, cell);
        page.provider_marks[index] = try page.add(.{ .pixels = scratch, .stride = cell * 4, .width = cell, .height = cell });
    }

    return page;
}

pub fn deinit(page: *SpritePage) void {
    page.allocator.free(page.pixels);
    page.* = undefined;
}

/// The cell side for one display scale, whole texels inside the bounds.
/// Example: `const cell = SpritePage.cellFor(viewport.scale);`
pub fn cellFor(scale: f32) u32 {
    const wanted: u32 = @intFromFloat(@round(mark_logical * @max(0.5, @min(8, scale))));
    return @max(min_cell, @min(max_cell, wanted));
}

/// Cells the page can hold in total.
/// Example: `try std.testing.expect(page.capacity() >= 67);`
pub fn capacity(page: *const SpritePage) u16 {
    return @intCast(page.columns * page.columns);
}

/// Favicon cells still free: the sheet keeps `max_favicons` at most.
/// Example: `if (page.faviconRoom() == 0) keepGlyph();`
pub fn faviconRoom(page: *const SpritePage) u16 {
    const used = page.count -| @as(u16, providers.len);
    return @min(max_favicons - @min(max_favicons, used), page.capacity() - page.count);
}

/// The embedded mark of a built-in provider; custom providers have none.
/// Example: `if (page.providerMark(agent.provider)) |mark| try canvas.spriteAt(box, mark);`
pub fn providerMark(page: *const SpritePage, provider: core.AgentProvider) ?Sprite {
    for (providers, page.provider_marks) |known, sprite| {
        if (known == provider) {
            return sprite;
        }
    }

    return null;
}

/// Copies a `cell` by `cell` straight-alpha favicon into the next free cell.
/// Example: `const sprite = try page.addFavicon(image);`
pub fn addFavicon(page: *SpritePage, image: ImageView) !Sprite {
    if (page.faviconRoom() == 0) {
        return error.SheetFull;
    }

    return page.add(image);
}

/// Texture coordinates of a sprite's cell: u0, v0, u1, v1 in the page.
/// Example: `const uv = page.uv(sprite);`
pub fn uv(page: *const SpritePage, sprite: Sprite) [4]f32 {
    const column: f32 = @floatFromInt(sprite.index % page.columns);
    const row: f32 = @floatFromInt(sprite.index / page.columns);
    const cell: f32 = @floatFromInt(page.cell);
    const extent: f32 = @floatFromInt(side);
    return .{ column * cell / extent, row * cell / extent, (column + 1) * cell / extent, (row + 1) * cell / extent };
}

fn add(page: *SpritePage, image: ImageView) !Sprite {
    if (image.width != page.cell or image.height != page.cell) {
        return error.SpriteSizeMismatch;
    }

    if (page.count >= page.capacity()) {
        return error.SheetFull;
    }

    const index = page.count;
    const left = @as(usize, index % page.columns) * page.cell;
    const top = @as(usize, index / page.columns) * page.cell;
    for (0..page.cell) |row| {
        const destination = page.pixels[((top + row) * side + left) * 4 ..][0 .. page.cell * 4];
        for (0..page.cell) |column| {
            const rgba = image.pixel(@intCast(column), @intCast(row));
            const alpha: u32 = rgba[3];
            const out = destination[column * 4 ..][0..4];
            inline for (0..3) |channel| {
                out[channel] = @intCast((@as(u32, rgba[channel]) * alpha + 127) / 255);
            }

            out[3] = rgba[3];
        }
    }

    page.count += 1;
    page.version +%= 1;
    return .{ .index = index };
}

test "the page holds the provider marks then at most 64 favicons and premultiplies" {
    var page = try SpritePage.init(std.testing.allocator, 16);
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, 3), page.count);
    try std.testing.expectEqual(@as(u16, 1024), page.capacity());
    try std.testing.expectEqual(max_favicons, page.faviconRoom());
    try std.testing.expect(page.providerMark(.claude) != null);
    try std.testing.expect(page.providerMark(.pi).?.index == 2);
    try std.testing.expect(page.providerMark(.unknown) == null);
    try std.testing.expect(page.providerMark(@enumFromInt(9)) == null);

    const half = [_]u8{ 200, 100, 0, 128 } ** (16 * 16);
    const image: ImageView = .{ .pixels = &half, .stride = 64, .width = 16, .height = 16 };
    const version = page.version;
    const first = try page.addFavicon(image);
    try std.testing.expectEqual(@as(u16, 3), first.index);
    try std.testing.expectEqual(version + 1, page.version);
    const cell = page.uv(first);
    const texel = page.pixels[(@as(usize, @intFromFloat(cell[1] * side)) * side + @as(usize, @intFromFloat(cell[0] * side))) * 4 ..][0..4];
    try std.testing.expectEqualSlices(u8, &.{ 100, 50, 0, 128 }, texel);
    for (1..max_favicons) |_| {
        _ = try page.addFavicon(image);
    }

    try std.testing.expectEqual(@as(u16, 0), page.faviconRoom());
    try std.testing.expectError(error.SheetFull, page.addFavicon(image));
    try std.testing.expectError(error.SpriteSizeMismatch, page.add(.{ .pixels = &half, .stride = 32, .width = 8, .height = 8 }));
}

test "cells follow the display scale inside the bounds" {
    try std.testing.expectEqual(@as(u32, 16), cellFor(1));
    try std.testing.expectEqual(@as(u32, 32), cellFor(2));
    try std.testing.expectEqual(@as(u32, 48), cellFor(3));
    try std.testing.expectEqual(@as(u32, max_cell), cellFor(4));
    try std.testing.expectEqual(@as(u32, min_cell), cellFor(0.1));
    try std.testing.expectError(error.InvalidSpriteCell, SpritePage.init(std.testing.allocator, 4));
}
