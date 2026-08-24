//! Geometry contract for the client chrome.

const ui = @import("../ui.zig");

pub const sidebar_width: u16 = 30;
pub const minimum_workbench_width: u16 = 20;

pub const Regions = struct {
    full: ui.Rect,
    top: ui.Rect,
    body: ui.Rect,
    sidebar: ui.Rect,
    workbench: ui.Rect,
    bottom: ui.Rect,
    tabs: ui.Rect,
    status: ui.Rect,

    pub fn calculate(width: u16, height: u16, sidebar_requested: bool) Regions {
        const full: ui.Rect = .{ .w = width, .h = height };
        const top_height: u16 = @intFromBool(height != 0);
        const bottom_height: u16 = @intFromBool(height >= 2);
        const top, const below_top = full.splitTop(top_height);
        const body, const bottom = below_top.splitBottom(bottom_height);

        const can_show_sidebar = sidebar_requested and
            body.w >= minimum_workbench_width + 12;
        const requested_width = @min(sidebar_width, body.w -| minimum_workbench_width);
        const actual_width: u16 = if (can_show_sidebar) requested_width else 0;
        const sidebar, const workbench = body.splitLeft(actual_width);

        const status_width = @min(@as(u16, 24), bottom.w / 2);
        const tabs_width = bottom.w - status_width;
        const tabs, const status = bottom.splitLeft(tabs_width);
        return .{
            .full = full,
            .top = top,
            .body = body,
            .sidebar = sidebar,
            .workbench = workbench,
            .bottom = bottom,
            .tabs = tabs,
            .status = status,
        };
    }
};

test "regions expose the complete chrome layout" {
    const regions = Regions.calculate(120, 40, true);
    try @import("std").testing.expectEqual(ui.Rect{ .w = 120, .h = 1 }, regions.top);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 1, .w = 30, .h = 38 }, regions.sidebar);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 30, .y = 1, .w = 90, .h = 38 }, regions.workbench);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "narrow layouts suppress the sidebar without changing requested state" {
    const regions = Regions.calculate(31, 20, true);
    try @import("std").testing.expect(regions.sidebar.isEmpty());
    try @import("std").testing.expectEqual(@as(u16, 31), regions.workbench.w);
}
