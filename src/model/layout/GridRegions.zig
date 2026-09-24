//! Splits the host grid between the sidebar, the tab bar, the workbench and
//! the status bar, for hosts that draw their chrome in cells.
const cellgrid = @import("cellgrid");
const std = @import("std");
const sidebar_layout = @import("sidebar.zig");
const GridRegions = @This();

full: cellgrid.Rect,
top: cellgrid.Rect,
body: cellgrid.Rect,
sidebar: cellgrid.Rect,
workbench: cellgrid.Rect,
bottom: cellgrid.Rect,

/// Example: `const regions = GridRegions.calculate(120, 40, true, 42);`
pub fn calculate(width: u16, height: u16, sidebar_visible: bool, sidebar_width: u16) GridRegions {
    const full: cellgrid.Rect = .{ .w = width, .h = height };
    const top_height: u16 = @intFromBool(height != 0);
    const bottom_height: u16 = @intFromBool(height >= 2);
    const actual_width = sidebar_layout.actualWidth(full.w, sidebar_visible, sidebar_width);
    const sidebar, const client = full.splitLeft(actual_width);
    const top, const below_top = client.splitTop(top_height);
    const body, const bottom = below_top.splitBottom(bottom_height);

    return .{
        .full = full,
        .top = top,
        .body = body,
        .sidebar = sidebar,
        .workbench = body,
        .bottom = bottom,
    };
}

test "regions expose the complete chrome layout" {
    const regions = calculate(120, 40, true, sidebar_layout.default_width);
    try std.testing.expectEqual(cellgrid.Rect{ .x = 42, .w = 78, .h = 1 }, regions.top);
    try std.testing.expectEqual(cellgrid.Rect{ .x = 0, .y = 0, .w = 42, .h = 40 }, regions.sidebar);
    try std.testing.expectEqual(cellgrid.Rect{ .x = 42, .y = 1, .w = 78, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(cellgrid.Rect{ .x = 42, .y = 39, .w = 78, .h = 1 }, regions.bottom);
}

test "hiding the sidebar expands both bars to the full client width" {
    const regions = calculate(120, 40, false, sidebar_layout.default_width);

    try std.testing.expectEqual(cellgrid.Rect{ .w = 120, .h = 1 }, regions.top);
    try std.testing.expectEqual(cellgrid.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "layouts below the minimum useful sidebar width suppress it" {
    const regions = calculate(61, 20, true, sidebar_layout.default_width);
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar starts at its minimum width on every viable host" {
    try std.testing.expectEqual(@as(u16, 42), calculate(62, 20, true, sidebar_layout.default_width).sidebar.w);
    try std.testing.expectEqual(@as(u16, 42), calculate(72, 20, true, sidebar_layout.default_width).sidebar.w);
    try std.testing.expectEqual(@as(u16, 42), calculate(120, 20, true, sidebar_layout.default_width).sidebar.w);
}

test "sidebar honors an arbitrary preferred width" {
    const regions = calculate(120, 20, true, 73);

    try std.testing.expectEqual(@as(u16, 73), regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 47), regions.workbench.w);
}
