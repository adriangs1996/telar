const RectType = @import("telar-core").Rect;
const LayoutSidebar = @import("LayoutSidebar.zig");
const actualWidth_module = @import("telar-client").actualWidth;
const Regions = @This();

full: RectType,
top: RectType,
body: RectType,
sidebar: RectType,
workbench: RectType,
bottom: RectType,

pub fn calculate(width: u16, height: u16, sidebar_spec: LayoutSidebar) Regions {
    const full: RectType = .{ .w = width, .h = height };
    const top_height: u16 = @intFromBool(height != 0);
    const bottom_height: u16 = @intFromBool(height >= 2);
    const actual_width = actualWidth_module(full.w, sidebar_spec.visible, sidebar_spec.preferred_width);
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
