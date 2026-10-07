//! The quads of one frame, in draw order. Cleared and refilled per frame so
//! the backend never sees a stale quad.
const std = @import("std");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const RoundedRect = @import("RoundedRect.zig");
const SpriteQuad = @import("SpriteQuad.zig");
const quad = @import("Quad.zig");
const OpacityEdge = @import("OpacityEdge.zig");
const Quad = quad.Quad;
const QuadList = @This();

allocator: std.mem.Allocator,
quads: std.ArrayList(Quad) = .empty,
limit: ?usize = null,
/// Quads pushed past `limit`, which the list left out; `clear` keeps the
/// count so a caller reusing the list per item still sees every drop. The
/// caller resets it once per frame.
dropped: usize = 0,

pub fn init(allocator: std.mem.Allocator) QuadList {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *QuadList) void {
    self.quads.deinit(self.allocator);
    self.* = undefined;
}

pub fn clear(self: *QuadList) void {
    self.quads.clearRetainingCapacity();
}

/// Appends one quad. A list at its `limit` keeps the quads it holds and
/// counts this one in `dropped`, so a frame draws what fits.
/// Example: `try list.push(quad);`
pub fn push(self: *QuadList, item: Quad) !void {
    if (self.limit) |limit| {
        if (self.quads.items.len >= limit) {
            self.dropped += 1;
            return;
        }

        self.quads.appendAssumeCapacity(item);
    } else {
        try self.quads.append(self.allocator, item);
    }
}

/// Clips visible ink at its pane boundary without changing the retained mesh.
/// Example: `try list.pushClipped(glyph, pane_bounds);`
pub fn pushClipped(self: *QuadList, item: Quad, clip: Rect) !void {
    const clipped = clipQuad(item, clip);
    if (clipped.width > 0 and clipped.height > 0) {
        try self.push(clipped);
    }
}

/// Appends a solid rectangle through the atlas' white texel.
/// Example: `try list.pushRect(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, Color.white);`
pub fn pushRect(self: *QuadList, rect: Rect, color: Color) !void {
    try self.push(.{
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
pub fn pushRounded(self: *QuadList, rect: Rect, shape: RoundedRect) !void {
    try self.push(.{
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
pub fn pushSprite(self: *QuadList, rect: Rect, sprite: SpriteQuad) !void {
    try self.push(.{
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

/// Appends one complete diagram texture. Pane clipping also adjusts its UVs.
/// Example: `try list.pushDiagram(bounds, 0);`
pub fn pushDiagram(self: *QuadList, rect: Rect, slot: u8) !void {
    try self.pushDiagramRegion(rect, slot, .{ 0, 0, 1, 1 });
}

/// Appends the part `uv` (u0, v0, u1, v1) of one diagram texture, so one
/// texture can hold several images side by side.
/// Example: `try list.pushDiagramRegion(bounds, 6, .{ 0, 0, 0.25, 1 });`
pub fn pushDiagramRegion(self: *QuadList, rect: Rect, slot: u8, uv: [4]f32) !void {
    if (slot >= quad.diagram_slot_count) {
        return error.InvalidDiagramSlot;
    }

    try self.push(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .u0 = uv[0],
        .v0 = uv[1],
        .u1 = uv[2],
        .v1 = uv[3],
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .texture = quad.diagram_texture + @as(f32, @floatFromInt(slot)),
    });
}

pub fn items(self: *const QuadList) []const Quad {
    return self.quads.items;
}

/// Fades existing ink toward an edge by each quad's center, so a label cut
/// by its box dissolves instead of ending mid-glyph.
/// Example: `list.fadeEdgeFrom(first_glyph, .{ .from = right - 24, .to = right });`
pub fn fadeEdgeFrom(self: *QuadList, start: usize, edge: OpacityEdge) void {
    for (self.quads.items[start..]) |*item| {
        item.a *= edge.at(item.x + item.width / 2);
    }
}

/// Fits newly painted ink inside a box, preserving aspect ratio and centering
/// both axes. Example: `list.fitFrom(first_icon_quad, icon_box);`
pub fn fitFrom(self: *QuadList, start: usize, bounds: Rect) void {
    var left = std.math.inf(f32);
    var top = std.math.inf(f32);
    var right = -std.math.inf(f32);
    var bottom = -std.math.inf(f32);
    for (self.items()[start..]) |item| {
        left = @min(left, item.x);
        top = @min(top, item.y);
        right = @max(right, item.x + item.width);
        bottom = @max(bottom, item.y + item.height);
    }

    if (right <= left or bottom <= top) {
        return;
    }

    const scale = @min(bounds.width / (right - left), bounds.height / (bottom - top));
    const x = bounds.x + (bounds.width - (right - left) * scale) / 2;
    const y = bounds.y + (bounds.height - (bottom - top) * scale) / 2;
    for (self.quads.items[start..]) |*item| {
        item.x = x + (item.x - left) * scale;
        item.y = y + (item.y - top) * scale;
        item.width *= scale;
        item.height *= scale;
    }
}

/// Fades a composed widget, including glyphs, sprites and rounded borders.
/// Example: `list.fadeFrom(first_card_quad, opacity);`
pub fn fadeFrom(self: *QuadList, start: usize, opacity: f32) void {
    for (self.quads.items[start..]) |*item| {
        item.a *= opacity;
        item.border_a *= opacity;
    }
}

/// Reserves a bounded frame at geometry changes. Example: `try list.reserve(4096);`
pub fn reserve(self: *QuadList, count: usize) !void {
    try self.quads.ensureTotalCapacityPrecise(self.allocator, count);
    self.limit = count;
}

/// Clips newly appended glyph quads and their texture coordinates together
/// and drops the ones left without area, so overflowing labels cost no quads.
/// Example: `list.clipFrom(first_glyph, cell_rect);`
pub fn clipFrom(self: *QuadList, start: usize, clip: Rect) void {
    var kept = start;
    for (self.quads.items[start..]) |item| {
        const clipped = clipQuad(item, clip);
        if (clipped.width > 0 and clipped.height > 0) {
            self.quads.items[kept] = clipped;
            kept += 1;
        }
    }

    self.quads.items.len = kept;
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
