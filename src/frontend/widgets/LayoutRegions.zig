const Regions = @This();
const ui = @import("../ui/root.zig");
const Sidebar = @import("LayoutSidebar.zig");
const source_namespace = @import("layout.zig");
full: ui.Rect,
top: ui.Rect,
body: ui.Rect,
sidebar: ui.Rect,
workbench: ui.Rect,
bottom: ui.Rect,

pub fn calculate(width: u16, height: u16, sidebar_spec: Sidebar) Regions {
    const full: ui.Rect = .{ .w = width, .h = height };
    const top_height: u16 = @intFromBool(height != 0);
    const bottom_height: u16 = @intFromBool(height >= 2);
    const actual_width = source_namespace.sidebar_geometry.actualWidth(full.w, sidebar_spec.visible, sidebar_spec.preferred_width);
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
