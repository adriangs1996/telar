const core = @import("telar-core");
const data = @import("model");
const LayoutSidebar = @import("LayoutSidebar.zig");
const Regions = @This();

full: core.Rect,
top: core.Rect,
body: core.Rect,
sidebar: core.Rect,
workbench: core.Rect,
bottom: core.Rect,

pub fn calculate(width: u16, height: u16, sidebar_spec: LayoutSidebar) Regions {
    const full: core.Rect = .{ .w = width, .h = height };
    const top_height: u16 = @intFromBool(height != 0);
    const bottom_height: u16 = @intFromBool(height >= 2);
    const actual_width = data.sidebar.actualWidth(full.w, sidebar_spec.visible, sidebar_spec.preferred_width);
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
