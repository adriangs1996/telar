//! Splits the host grid between the sidebar, the tab bar, the workbench and
//! the status bar, for hosts that draw their chrome in cells.
const cellgrid = @import("cellgrid");
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
