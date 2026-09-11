//! Collision-free geometry for the three bottom-bar positions.

const std = @import("std");
const ui = @import("../ui/root.zig");

pub const Widths = @import("Widths.zig");

pub const Regions = @import("BarLayoutRegions.zig");

test "bar regions preserve tabs and never overlap" {
    const regions = Regions.calculate(.{ .w = 60, .h = 1 }, .{
        .desired = .{ 40, 40, 40 },
        .tabs_index = 1,
    });

    try std.testing.expect(regions.items[1].w >= 16);
    try std.testing.expect(regions.items[0].x + regions.items[0].w <= regions.items[1].x);
    try std.testing.expect(regions.items[1].x + regions.items[1].w <= regions.items[2].x);
    try std.testing.expect(regions.items[2].x + regions.items[2].w <= 60);
}

test "short blocks keep their requested widths" {
    const regions = Regions.calculate(.{ .w = 120, .h = 1 }, .{
        .desired = .{ 24, 0, 30 },
        .tabs_index = 2,
    });

    try std.testing.expectEqual(@as(u16, 24), regions.items[0].w);
    try std.testing.expectEqual(@as(u16, 0), regions.items[1].w);
    try std.testing.expectEqual(@as(u16, 30), regions.items[2].w);
}
