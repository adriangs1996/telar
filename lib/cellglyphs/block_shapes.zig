//! Unicode block-element semantics: slabs of eighths, quadrant sets and shades.
const std = @import("std");
const Slab = @import("BlockSlab.zig");

pub const Side = enum { top, bottom, left, right };

/// Quadrant bits: 1 upper-left, 2 upper-right, 4 lower-left, 8 lower-right.
pub const Shape = union(enum) {
    slab: Slab,
    quadrants: u4,
    /// Fraction of the cell area covered by a shade.
    shade: f32,
};

/// Decodes U+2580 through U+259F; other codepoints are the caller's error.
/// Example: `const shape = block_shapes.get(0x2588);`
pub fn get(codepoint: u21) Shape {
    std.debug.assert(codepoint >= 0x2580 and codepoint <= 0x259f);
    const quadrant_sets = [_]u4{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
    return switch (codepoint) {
        0x2580 => .{ .slab = .{ .side = .top, .eighths = 4 } },
        0x2581...0x2588 => .{ .slab = .{ .side = .bottom, .eighths = @intCast(codepoint - 0x2580) } },
        0x2589...0x258f => .{ .slab = .{ .side = .left, .eighths = @intCast(0x2590 - codepoint) } },
        0x2590 => .{ .slab = .{ .side = .right, .eighths = 4 } },
        0x2591 => .{ .shade = 0.25 },
        0x2592 => .{ .shade = 0.5 },
        0x2593 => .{ .shade = 0.75 },
        0x2594 => .{ .slab = .{ .side = .top, .eighths = 1 } },
        0x2595 => .{ .slab = .{ .side = .right, .eighths = 1 } },
        0x2596...0x259f => .{ .quadrants = quadrant_sets[codepoint - 0x2596] },
        else => unreachable,
    };
}

test "every block element decodes to the Unicode chart" {
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .top, .eighths = 4 } }, get(0x2580));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .bottom, .eighths = 1 } }, get(0x2581));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .bottom, .eighths = 4 } }, get(0x2584));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .bottom, .eighths = 8 } }, get(0x2588));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .left, .eighths = 7 } }, get(0x2589));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .left, .eighths = 4 } }, get(0x258c));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .left, .eighths = 1 } }, get(0x258f));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .right, .eighths = 4 } }, get(0x2590));
    try std.testing.expectEqual(Shape{ .shade = 0.25 }, get(0x2591));
    try std.testing.expectEqual(Shape{ .shade = 0.5 }, get(0x2592));
    try std.testing.expectEqual(Shape{ .shade = 0.75 }, get(0x2593));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .top, .eighths = 1 } }, get(0x2594));
    try std.testing.expectEqual(Shape{ .slab = .{ .side = .right, .eighths = 1 } }, get(0x2595));
    try std.testing.expectEqual(Shape{ .quadrants = 4 }, get(0x2596));
    try std.testing.expectEqual(Shape{ .quadrants = 8 }, get(0x2597));
    try std.testing.expectEqual(Shape{ .quadrants = 1 }, get(0x2598));
    try std.testing.expectEqual(Shape{ .quadrants = 1 | 4 | 8 }, get(0x2599));
    try std.testing.expectEqual(Shape{ .quadrants = 1 | 8 }, get(0x259a));
    try std.testing.expectEqual(Shape{ .quadrants = 1 | 2 | 4 }, get(0x259b));
    try std.testing.expectEqual(Shape{ .quadrants = 1 | 2 | 8 }, get(0x259c));
    try std.testing.expectEqual(Shape{ .quadrants = 2 }, get(0x259d));
    try std.testing.expectEqual(Shape{ .quadrants = 2 | 4 }, get(0x259e));
    try std.testing.expectEqual(Shape{ .quadrants = 2 | 4 | 8 }, get(0x259f));
}
