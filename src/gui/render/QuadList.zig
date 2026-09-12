//! The quads of one frame, in draw order. Cleared and refilled per frame so
//! the backend never sees a stale quad.
const std = @import("std");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
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

pub fn items(list: *const QuadList) []const Quad {
    return list.quads.items;
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
    try list.quads.ensureTotalCapacity(list.allocator, count);
    list.limit = count;
}

/// Clips newly appended glyph quads and their texture coordinates together.
/// Example: `list.clipFrom(first_glyph, cell_rect);`
pub fn clipFrom(list: *QuadList, start: usize, clip: Rect) void {
    for (list.quads.items[start..]) |*item| {
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
    }
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
}
