//! The quads of one frame, in draw order. Cleared and refilled per frame so
//! the backend never sees a stale quad.
const std = @import("std");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const RoundedRect = @import("RoundedRect.zig");
const SpriteQuad = @import("SpriteQuad.zig");
const quad = @import("Quad.zig");
const Quad = quad.Quad;
const QuadList = @This();

allocator: std.mem.Allocator,
quads: std.ArrayList(Quad) = .empty,
limit: ?usize = null,

pub fn init(allocator: std.mem.Allocator) QuadList {
    return .{ .allocator = allocator };
}

pub fn deinit(list: *QuadList) void {
    list.quads.deinit(list.allocator);
    list.* = undefined;
}

pub fn clear(list: *QuadList) void {
    list.quads.clearRetainingCapacity();
}

pub fn push(list: *QuadList, item: Quad) !void {
    if (list.limit) |limit| {
        if (list.quads.items.len >= limit) {
            return error.NativeQuadBudgetExceeded;
        }

        list.quads.appendAssumeCapacity(item);
    } else {
        try list.quads.append(list.allocator, item);
    }
}

/// Clips visible ink at its pane boundary without changing the retained mesh.
/// Example: `try list.pushClipped(glyph, pane_bounds);`
pub fn pushClipped(list: *QuadList, item: Quad, clip: Rect) !void {
    const clipped = clipQuad(item, clip);
    if (clipped.width > 0 and clipped.height > 0) {
        try list.push(clipped);
    }
}

/// Appends a solid rectangle through the atlas' white texel.
/// Example: `try list.pushRect(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, Color.white);`
pub fn pushRect(list: *QuadList, rect: Rect, color: Color) !void {
    try list.push(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .u0 = quad.solid_uv[0],
        .v0 = quad.solid_uv[1],
        .u1 = quad.solid_uv[2],
        .v1 = quad.solid_uv[3],
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    });
}

/// Appends one rounded or outlined surface; the shader resolves its shape.
/// Example: `try list.pushRounded(card, .{ .fill = surface, .radius = 8 });`
pub fn pushRounded(list: *QuadList, rect: Rect, shape: RoundedRect) !void {
    try list.push(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .u0 = quad.solid_uv[0],
        .v0 = quad.solid_uv[1],
        .u1 = quad.solid_uv[2],
        .v1 = quad.solid_uv[3],
        .r = shape.fill.r,
        .g = shape.fill.g,
        .b = shape.fill.b,
        .a = shape.fill.a,
        .radius = shape.radius,
        .border = shape.border,
        .border_r = shape.border_color.r,
        .border_g = shape.border_color.g,
        .border_b = shape.border_color.b,
        .border_a = shape.border_color.a,
    });
}

/// Appends one cell of the RGBA sprite page scaled into `rect`; the tint's
/// alpha fades it and its RGB multiplies the artwork, white keeps it as is.
/// Example: `try list.pushSprite(box, page.uv(mark), Color.white);`
pub fn pushSprite(list: *QuadList, rect: Rect, sprite: SpriteQuad) !void {
    try list.push(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .u0 = sprite.uv[0],
        .v0 = sprite.uv[1],
        .u1 = sprite.uv[2],
        .v1 = sprite.uv[3],
        .r = sprite.tint.r,
        .g = sprite.tint.g,
        .b = sprite.tint.b,
        .a = sprite.tint.a,
        .texture = quad.sprite_texture,
    });
}

pub fn items(list: *const QuadList) []const Quad {
    return list.quads.items;
}

test "plain rectangles keep zero shape attributes and rounded surfaces carry theirs" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.pushRect(.{ .x = 1, .y = 2, .width = 3, .height = 4 }, Color.white);
    const plain = list.items()[0];
    try std.testing.expectEqualDeep(Quad{ .x = 1, .y = 2, .width = 3, .height = 4, .u0 = quad.solid_uv[0], .v0 = quad.solid_uv[1], .u1 = quad.solid_uv[2], .v1 = quad.solid_uv[3], .r = 1, .g = 1, .b = 1, .a = 1 }, plain);
    try std.testing.expectEqual(@as(f32, 0), plain.radius);
    try std.testing.expectEqual(@as(f32, 0), plain.border);
    try std.testing.expectEqual(@as(f32, 0), plain.border_a);

    try list.pushRounded(.{ .x = 1, .y = 2, .width = 3, .height = 4 }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .radius = 8, .border = 2, .border_color = Color.white });
    const ring = list.items()[1];
    try std.testing.expectEqual(@as(f32, 8), ring.radius);
    try std.testing.expectEqual(@as(f32, 2), ring.border);
    try std.testing.expectEqual(@as(f32, 0), ring.a);
    try std.testing.expectEqual(@as(f32, 1), ring.border_a);
    try std.testing.expectEqual(plain.u0, ring.u0);
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Quad));
    try std.testing.expectEqual(@as(f32, 0), plain.texture);
    try std.testing.expectEqual(@as(f32, 0), ring.texture);

    try list.pushSprite(.{ .x = 1, .y = 2, .width = 3, .height = 4 }, .{ .uv = .{ 0.25, 0.5, 0.75, 1 }, .tint = Color.white });
    const sprite = list.items()[2];
    try std.testing.expectEqual(quad.sprite_texture, sprite.texture);
    try std.testing.expectEqual(@as(f32, 0.25), sprite.u0);
    try std.testing.expectEqual(@as(f32, 1), sprite.v1);
    try std.testing.expectEqual(@as(f32, 0), sprite.radius);
    try std.testing.expectEqual(@as(f32, 0), sprite.border);
}

test "clear keeps capacity and drops quads" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();

    try list.pushRect(.{ .x = 1, .y = 2, .width = 3, .height = 4 }, Color.white);
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    try std.testing.expectEqual(@as(f32, 3), list.items()[0].width);

    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.items().len);
}

/// Reserves a bounded frame at geometry changes. Example: `try list.reserve(4096);`
pub fn reserve(list: *QuadList, count: usize) !void {
    try list.quads.ensureTotalCapacityPrecise(list.allocator, count);
    list.limit = count;
}

/// Clips newly appended glyph quads and their texture coordinates together
/// and drops the ones left without area, so overflowing labels cost no quads.
/// Example: `list.clipFrom(first_glyph, cell_rect);`
pub fn clipFrom(list: *QuadList, start: usize, clip: Rect) void {
    var kept = start;
    for (list.quads.items[start..]) |item| {
        const clipped = clipQuad(item, clip);
        if (clipped.width > 0 and clipped.height > 0) {
            list.quads.items[kept] = clipped;
            kept += 1;
        }
    }

    list.quads.items.len = kept;
}

fn clipQuad(original: Quad, clip: Rect) Quad {
    if (original.x >= clip.x and original.y >= clip.y and original.x + original.width <= clip.x + clip.width and original.y + original.height <= clip.y + clip.height) {
        return original;
    }

    var item = original;
    const left = @max(item.x, clip.x);
    const top = @max(item.y, clip.y);
    const right = @max(left, @min(item.x + item.width, clip.x + clip.width));
    const bottom = @max(top, @min(item.y + item.height, clip.y + clip.height));
    if (item.width > 0 and item.height > 0) {
        const du = (item.u1 - item.u0) / item.width;
        const dv = (item.v1 - item.v0) / item.height;
        item.u1 = item.u0 + (right - item.x) * du;
        item.v1 = item.v0 + (bottom - item.y) * dv;
        item.u0 += (left - item.x) * du;
        item.v0 += (top - item.y) * dv;
    }

    item.x = left;
    item.y = top;
    item.width = right - left;
    item.height = bottom - top;
    return item;
}

test "clipping a glyph adjusts texture coordinates without leaking into the next pane" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.push(.{ .x = 5, .y = 2, .width = 20, .height = 10, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1, .a = 1 });
    list.clipFrom(0, .{ .x = 10, .y = 0, .width = 10, .height = 7 });
    const clipped = list.items()[0];
    try std.testing.expectEqual(@as(f32, 10), clipped.x);
    try std.testing.expectEqual(@as(f32, 10), clipped.width);
    try std.testing.expectEqual(@as(f32, 5), clipped.height);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), clipped.u0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), clipped.u1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), clipped.v1, 0.001);
    try list.push(.{ .x = 30, .y = 2, .width = 5, .height = 5, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1, .a = 1 });
    try list.push(.{ .x = 12, .y = 2, .width = 5, .height = 5, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1, .a = 1 });
    list.clipFrom(1, .{ .x = 10, .y = 0, .width = 10, .height = 7 });
    try std.testing.expectEqual(@as(usize, 2), list.items().len);
    try std.testing.expectEqual(@as(f32, 12), list.items()[1].x);
}

test "pane composition preserves contained texture coordinates and omits outside ink" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const clip: Rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 };
    var glyph: Quad = .{ .x = 11, .y = 22, .width = 7, .height = 13, .u0 = 0.13, .v0 = 0.41, .u1 = 0.27, .v1 = 0.57, .r = 1, .g = 1, .b = 1, .a = 1 };
    try list.pushClipped(glyph, clip);
    try std.testing.expectEqualDeep(glyph, list.items()[0]);
    glyph.x = clip.x + clip.width;
    try list.pushClipped(glyph, clip);
    glyph.x = clip.x - glyph.width;
    try list.pushClipped(glyph, clip);
    glyph.x = clip.x;
    glyph.y = clip.y - glyph.height;
    try list.pushClipped(glyph, clip);
    glyph.y = clip.y + clip.height;
    try list.pushClipped(glyph, clip);
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
}
