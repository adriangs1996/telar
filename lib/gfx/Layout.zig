//! Immediate pixel layout over caller-owned children. Nested containers use
//! their parent's assigned rectangle; no retained tree or allocation is needed.
const length = @import("length.zig");
const alignment_module = @import("alignment.zig");
const std = @import("std");
const Rect = @import("Rect.zig");
const Item = @import("Item.zig");
const Insets = @import("Insets.zig");
const Layout = @This();

pub const Direction = enum { row, column, overlay };

area: Rect,
direction: Direction = .row,
padding: Insets = .{},
gap: f32 = 0,
alignment: alignment_module.Alignment = .start,
cross_alignment: alignment_module.Alignment = .start,

/// Places children in O(n) time. Fixed/content sizes reserve their space
/// first; fill children split the remainder equally above their minimums.
/// A capped maximum leaves its excess unused; alignment places that space.
/// Minimums may overflow in declaration order, so the owning container must
/// clip both drawing and hit regions to its bounds. This method changes only
/// geometry. Invalid measurements fail before changing any child rectangle.
/// Example: `try (Layout{ .area = bounds, .gap = 8 }).resolve(&children);`
pub fn resolve(self: Layout, children: []Item) !void {
    try self.validate(children);
    const area = self.content();
    if (self.direction == .overlay) {
        for (children) |*child| {
            const size = [2]f32{ childSize(child, 0, area.width), childSize(child, 1, area.height) };
            child.bounds = .{
                .x = area.x + offset(self.alignment, @max(0, area.width - size[0])),
                .y = area.y + offset(self.cross_alignment, @max(0, area.height - size[1])),
                .width = size[0],
                .height = size[1],
            };
        }

        return;
    }

    const axis: usize = if (self.direction == .row) 0 else 1;
    const available = if (axis == 0) area.width else area.height;
    const cross = if (axis == 0) area.height else area.width;
    const gaps = self.gap * @as(f32, @floatFromInt(children.len -| 1));
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

    var cursor = offset(self.alignment, @max(0, available - used));
    for (children) |*child| {
        const main = mainSize(child, axis, .{ available, share });
        const side = childSize(child, axis ^ 1, cross);
        const position = offset(self.cross_alignment, @max(0, cross - side));
        child.bounds = if (axis == 0)
            .{ .x = area.x + cursor, .y = area.y + position, .width = main, .height = side }
        else
            .{ .x = area.x + position, .y = area.y + cursor, .width = side, .height = main };
        cursor += main + self.gap;
    }
}

/// Returns the available rectangle after bounded padding.
/// Example: `const inner = (Layout{ .area = bounds, .padding = padding }).content();`
pub fn content(self: Layout) Rect {
    const left = @min(self.padding.left, self.area.width);
    const top = @min(self.padding.top, self.area.height);
    return .{
        .x = self.area.x + left,
        .y = self.area.y + top,
        .width = @max(0, self.area.width - left - self.padding.right),
        .height = @max(0, self.area.height - top - self.padding.bottom),
    };
}

fn validate(self: Layout, children: []const Item) !void {
    if (!std.math.isFinite(self.area.x) or !std.math.isFinite(self.area.y)) {
        return error.InvalidLayout;
    }

    for ([_]f32{ self.area.width, self.area.height, self.padding.left, self.padding.top, self.padding.right, self.padding.bottom, self.gap }) |value| {
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

fn policy(child: *const Item, axis: usize) length.Length {
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

fn offset(alignment: alignment_module.Alignment, free: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @floor(free / 2),
        .end => free,
    };
}
