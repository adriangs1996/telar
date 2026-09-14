//! Immediate pixel layout over caller-owned children. Nested containers use
//! their parent's assigned rectangle; no retained tree or allocation is needed.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Item = @import("Item.zig");
const Length = @import("length.zig").Length;
const Alignment = @import("alignment.zig").Alignment;
const Insets = @import("Insets.zig");
const Layout = @This();

pub const Direction = enum { row, column, overlay };

area: Rect,
direction: Direction = .row,
padding: Insets = .{},
gap: f32 = 0,
alignment: Alignment = .start,
cross_alignment: Alignment = .start,

/// Places children in O(n) time. Fixed/content sizes reserve their space
/// first; fill children split the remainder equally above their minimums.
/// A capped maximum leaves its excess unused; alignment places that space.
/// Minimums may overflow in declaration order, so the owning container must
/// clip both drawing and hit regions to its bounds. This method changes only
/// geometry. Invalid measurements fail before changing any child rectangle.
/// Example: `try (Layout{ .area = bounds, .gap = 8 }).resolve(&children);`
pub fn resolve(layout: Layout, children: []Item) !void {
    try layout.validate(children);
    const area = layout.content();
    if (layout.direction == .overlay) {
        for (children) |*child| {
            const size = [2]f32{ childSize(child, 0, area.width), childSize(child, 1, area.height) };
            child.bounds = .{
                .x = area.x + offset(layout.alignment, @max(0, area.width - size[0])),
                .y = area.y + offset(layout.cross_alignment, @max(0, area.height - size[1])),
                .width = size[0],
                .height = size[1],
            };
        }

        return;
    }

    const axis: usize = if (layout.direction == .row) 0 else 1;
    const available = if (axis == 0) area.width else area.height;
    const cross = if (axis == 0) area.height else area.width;
    const gaps = layout.gap * @as(f32, @floatFromInt(children.len -| 1));
    var reserved = gaps;
    var fills: usize = 0;
    for (children) |*child| {
        if (policy(child, axis) == .fill) {
            fills += 1;
            reserved += child.minimum[axis];
        } else {
            reserved += childSize(child, axis, available);
        }
    }

    const share = if (fills == 0) 0 else @max(0, available - reserved) / @as(f32, @floatFromInt(fills));
    var used = gaps;
    for (children) |*child| {
        used += mainSize(child, axis, .{ available, share });
    }

    var cursor = offset(layout.alignment, @max(0, available - used));
    for (children) |*child| {
        const main = mainSize(child, axis, .{ available, share });
        const side = childSize(child, axis ^ 1, cross);
        const position = offset(layout.cross_alignment, @max(0, cross - side));
        child.bounds = if (axis == 0)
            .{ .x = area.x + cursor, .y = area.y + position, .width = main, .height = side }
        else
            .{ .x = area.x + position, .y = area.y + cursor, .width = side, .height = main };
        cursor += main + layout.gap;
    }
}

/// Returns the available rectangle after bounded padding.
/// Example: `const inner = (Layout{ .area = bounds, .padding = padding }).content();`
pub fn content(layout: Layout) Rect {
    const left = @min(layout.padding.left, layout.area.width);
    const top = @min(layout.padding.top, layout.area.height);
    return .{
        .x = layout.area.x + left,
        .y = layout.area.y + top,
        .width = @max(0, layout.area.width - left - layout.padding.right),
        .height = @max(0, layout.area.height - top - layout.padding.bottom),
    };
}

fn validate(layout: Layout, children: []const Item) !void {
    if (!std.math.isFinite(layout.area.x) or !std.math.isFinite(layout.area.y)) {
        return error.InvalidLayout;
    }

    for ([_]f32{ layout.area.width, layout.area.height, layout.padding.left, layout.padding.top, layout.padding.right, layout.padding.bottom, layout.gap }) |value| {
        if (!validLength(value)) {
            return error.InvalidLayout;
        }
    }

    for (children) |*child| {
        for (0..2) |axis| {
            if (!validLength(child.intrinsic[axis]) or !validLength(child.minimum[axis]) or !validLength(child.maximum[axis]) or child.minimum[axis] > child.maximum[axis]) {
                return error.InvalidLayout;
            }

            switch (policy(child, axis)) {
                .fixed => |value| if (!validLength(value)) {
                    return error.InvalidLayout;
                },
                else => {},
            }
        }
    }
}

fn validLength(value: f32) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 65535;
}

fn policy(child: *const Item, axis: usize) Length {
    return if (axis == 0) child.width else child.height;
}

fn childSize(child: *const Item, axis: usize, available: f32) f32 {
    const wanted = switch (policy(child, axis)) {
        .fixed => |value| value,
        .content => child.intrinsic[axis],
        .fill => available,
    };
    return @max(child.minimum[axis], @min(wanted, child.maximum[axis]));
}

fn mainSize(child: *const Item, axis: usize, available_and_share: [2]f32) f32 {
    return if (policy(child, axis) == .fill)
        @min(child.maximum[axis], child.minimum[axis] + available_and_share[1])
    else
        childSize(child, axis, available_and_share[0]);
}

fn offset(alignment: Alignment, free: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @floor(free / 2),
        .end => free,
    };
}

test "pixel layout combines measured fixed and fill children without allocations" {
    var children = [_]Item{
        .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 12 } },
        .{ .width = .content, .intrinsic = .{ 30, 10 } },
        .{ .minimum = .{ 10, 0 } },
        .{},
    };
    try (Layout{ .area = .{ .x = 10, .y = 20, .width = 200, .height = 40 }, .padding = .{ .left = 5, .right = 5 }, .gap = 4, .cross_alignment = .center }).resolve(&children);
    try std.testing.expectEqualDeep(Rect{ .x = 15, .y = 34, .width = 20, .height = 12 }, children[0].bounds);
    try std.testing.expectEqual(@as(f32, 30), children[1].bounds.width);
    try std.testing.expectEqual(@as(f32, 69), children[2].bounds.width);
    try std.testing.expectEqual(@as(f32, 59), children[3].bounds.width);
    try std.testing.expectEqual(@as(f32, 205), children[3].bounds.x + children[3].bounds.width);
}

test "nested column and overlay layouts share their assigned pixel rectangles" {
    var rows = [_]Item{ .{ .height = .{ .fixed = 10 } }, .{}, .{ .height = .{ .fixed = 15 } } };
    try (Layout{ .area = .{ .x = 0, .y = 0, .width = 100, .height = 60 }, .direction = .column, .gap = 5 }).resolve(&rows);
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 15, .width = 100, .height = 25 }, rows[1].bounds);
    var layers = [_]Item{ .{}, .{ .width = .content, .height = .content, .intrinsic = .{ 20, 5 } } };
    try (Layout{ .area = rows[1].bounds, .direction = .overlay, .alignment = .end, .cross_alignment = .center }).resolve(&layers);
    try std.testing.expectEqualDeep(rows[1].bounds, layers[0].bounds);
    try std.testing.expectEqualDeep(Rect{ .x = 80, .y = 25, .width = 20, .height = 5 }, layers[1].bounds);
}

test "pixel layout preserves minimums and rejects invalid constraints before mutation" {
    var children = [_]Item{ .{ .minimum = .{ 12, 0 } }, .{ .width = .content, .intrinsic = .{ 40, 0 }, .maximum = .{ 20, 65535 } } };
    const layout: Layout = .{ .area = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .padding = .{ .left = 50 }, .gap = 3 };
    try layout.resolve(&children);
    try std.testing.expectEqual(@as(f32, 12), children[0].bounds.width);
    try std.testing.expectEqual(@as(f32, 20), children[1].bounds.width);
    const first = children[0].bounds;
    children[1].intrinsic[0] = std.math.nan(f32);
    try std.testing.expectError(error.InvalidLayout, layout.resolve(&children));
    try std.testing.expectEqualDeep(first, children[0].bounds);
    try layout.resolve(&.{});
}

test "capped fill shares leave excess for alignment and never violate maximums" {
    var children = [_]Item{ .{ .maximum = .{ 10, 65535 } }, .{} };
    try (Layout{ .area = .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .alignment = .end }).resolve(&children);
    try std.testing.expectEqualDeep(Rect{ .x = 40, .y = 0, .width = 10, .height = 20 }, children[0].bounds);
    try std.testing.expectEqualDeep(Rect{ .x = 50, .y = 0, .width = 50, .height = 20 }, children[1].bounds);
}

test "pixel layout rejects nonfinite negative and reversed constraints atomically" {
    const original: Rect = .{ .x = 3, .y = 4, .width = 5, .height = 6 };
    var children = [_]Item{.{ .bounds = original }};
    const area: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        try std.testing.expectError(error.InvalidLayout, (Layout{ .area = area, .gap = invalid }).resolve(&children));
        try std.testing.expectError(error.InvalidLayout, (Layout{ .area = area, .padding = .{ .left = invalid } }).resolve(&children));
        children[0].width = .{ .fixed = invalid };
        try std.testing.expectError(error.InvalidLayout, (Layout{ .area = area }).resolve(&children));
        try std.testing.expectEqualDeep(original, children[0].bounds);
    }

    children[0].width = .fill;
    children[0].minimum[0] = 11;
    children[0].maximum[0] = 10;
    try std.testing.expectError(error.InvalidLayout, (Layout{ .area = area }).resolve(&children));
    try std.testing.expectEqualDeep(original, children[0].bounds);
}
