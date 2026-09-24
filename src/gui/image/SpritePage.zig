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
const imaging = @import("imaging");
const ImageView = imaging.ImageView;
const box_filter = imaging.box_filter;
const SpritePage = @This();

/// One page, square, in texels.
pub const side: u32 = 512;
/// The provider mark of the card is this many logical pixels; a cell is
/// that size at the display scale so the mark samples one texel per pixel.
pub const mark_logical: f32 = 16;
pub const min_cell: u32 = 8;
pub const max_cell: u32 = 48;
pub const max_favicons: u16 = 64;
const provider_slot: u32 = 64;
const providers = [_]core.AgentProvider{ .claude, .codex, .pi };

comptime {
    std.debug.assert(assets.provider_symbols_rgba.len == providers.len * provider_slot * provider_slot * 4);
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
        const slot: ImageView = .{ .pixels = assets.provider_symbols_rgba, .stride = providers.len * provider_slot * 4, .x = @intCast(index * provider_slot), .width = provider_slot, .height = provider_slot };
        box_filter.resample(slot, scratch, cell);
        page.provider_marks[index] = try page.add(.{ .pixels = scratch, .stride = cell * 4, .width = cell, .height = cell });
    }

    return page;
}

pub fn deinit(self: *SpritePage) void {
    self.allocator.free(self.pixels);
    self.* = undefined;
}

/// The cell side for one display scale, whole texels inside the bounds.
/// Example: `const cell = SpritePage.cellFor(viewport.scale);`
pub fn cellFor(scale: f32) u32 {
    const wanted: u32 = @intFromFloat(@round(mark_logical * @max(0.5, @min(8, scale))));
    return @max(min_cell, @min(max_cell, wanted));
}

/// Cells the page can hold in total.
/// Example: `try std.testing.expect(page.capacity() >= 67);`
pub fn capacity(self: *const SpritePage) u16 {
    return @intCast(self.columns * self.columns);
}

/// Favicon cells still free: the sheet keeps `max_favicons` at most.
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

/// Copies a `cell` by `cell` straight-alpha favicon into the next free cell.
/// Example: `const sprite = try page.addFavicon(image);`
pub fn addFavicon(self: *SpritePage, image: ImageView) !Sprite {
    if (self.faviconRoom() == 0) {
        return error.SheetFull;
    }

    return self.add(image);
}

/// Texture coordinates of a sprite's cell: u0, v0, u1, v1 in the page.
/// Example: `const uv = page.uv(sprite);`
pub fn uv(self: *const SpritePage, sprite: Sprite) [4]f32 {
    const column: f32 = @floatFromInt(sprite.index % self.columns);
    const row: f32 = @floatFromInt(sprite.index / self.columns);
    const cell: f32 = @floatFromInt(self.cell);
    const extent: f32 = @floatFromInt(side);
    return .{ column * cell / extent, row * cell / extent, (column + 1) * cell / extent, (row + 1) * cell / extent };
}

fn add(self: *SpritePage, image: ImageView) !Sprite {
    if (image.width != self.cell or image.height != self.cell) {
        return error.SpriteSizeMismatch;
    }

    if (self.count >= self.capacity()) {
        return error.SheetFull;
    }

    const index = self.count;
    const left = @as(usize, index % self.columns) * self.cell;
    const top = @as(usize, index / self.columns) * self.cell;
    for (0..self.cell) |row| {
        const destination = self.pixels[((top + row) * side + left) * 4 ..][0 .. self.cell * 4];
        for (0..self.cell) |column| {
            destination[column * 4 ..][0..4].* = imaging.premultiply.pixel(image.pixel(@intCast(column), @intCast(row)));
        }
    }

    self.count += 1;
    self.version +%= 1;
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

test "provider symbols preserve alpha and OpenAI is a tintable white mask" {
    var page = try SpritePage.init(std.testing.allocator, 32);
    defer page.deinit();
    for (providers) |provider| {
        const sprite = page.providerMark(provider).?;
        const left = @as(usize, sprite.index) * page.cell;
        var visible: usize = 0;
        var transparent: usize = 0;
        for (0..page.cell) |y| {
            for (0..page.cell) |x| {
                const rgba = page.pixels[(y * side + left + x) * 4 ..][0..4];
                if (provider == .codex) {
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
