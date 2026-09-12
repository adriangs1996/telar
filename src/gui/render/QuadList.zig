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
    try list.quads.append(list.allocator, item);
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
