//! Geometry contract for the client chrome.

const LayoutRegions = @import("LayoutRegions.zig");
const default_width_module = @import("telar-client").default_width;
const std = @import("std");
const RectType = @import("telar-core").Rect;

test "regions expose the complete chrome layout" {
    const regions = LayoutRegions.calculate(120, 40, .{ .visible = true, .preferred_width = default_width_module });
    try std.testing.expectEqual(RectType{ .x = 42, .w = 78, .h = 1 }, regions.top);
    try std.testing.expectEqual(RectType{ .x = 0, .y = 0, .w = 42, .h = 40 }, regions.sidebar);
    try std.testing.expectEqual(RectType{ .x = 42, .y = 1, .w = 78, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(RectType{ .x = 42, .y = 39, .w = 78, .h = 1 }, regions.bottom);
}

test "hiding the sidebar expands both bars to the full client width" {
    const regions = LayoutRegions.calculate(120, 40, .{ .visible = false, .preferred_width = default_width_module });

    try std.testing.expectEqual(RectType{ .w = 120, .h = 1 }, regions.top);
    try std.testing.expectEqual(RectType{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "layouts below the minimum useful sidebar width suppress it" {
    const regions = LayoutRegions.calculate(61, 20, .{ .visible = true, .preferred_width = default_width_module });
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar starts at its minimum width on every viable host" {
    try std.testing.expectEqual(@as(u16, 42), LayoutRegions.calculate(62, 20, .{ .visible = true, .preferred_width = default_width_module }).sidebar.w);
    try std.testing.expectEqual(@as(u16, 42), LayoutRegions.calculate(72, 20, .{ .visible = true, .preferred_width = default_width_module }).sidebar.w);
    try std.testing.expectEqual(@as(u16, 42), LayoutRegions.calculate(120, 20, .{ .visible = true, .preferred_width = default_width_module }).sidebar.w);
}

test "sidebar honors an arbitrary preferred width" {
    const regions = LayoutRegions.calculate(120, 20, .{ .visible = true, .preferred_width = 73 });

    try std.testing.expectEqual(@as(u16, 73), regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 47), regions.workbench.w);
}
