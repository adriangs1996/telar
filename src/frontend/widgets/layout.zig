//! Geometry contract for the client chrome.

const ui = @import("../ui.zig");

pub const minimum_sidebar_width: u16 = 42;
pub const sidebar_width: u16 = 62;
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
            body.w >= minimum_workbench_width + minimum_sidebar_width;
        const requested_width = @min(sidebar_width, body.w -| minimum_workbench_width);
        const actual_width: u16 = if (can_show_sidebar) requested_width else 0;
        const sidebar, const workbench = body.splitLeft(actual_width);

        // Status sits on the left and the tabs anchor to the right edge. The
        // width fits the widest metrics line ("⚙ 100%  ▤ 99.9G  ⚡ 100%")
        // instead of the old 24-column cap that truncated it.
        const status_width = @min(@as(u16, 26), bottom.w / 2);
        const status, const tabs = bottom.splitLeft(status_width);
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
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 1, .w = 62, .h = 38 }, regions.sidebar);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 62, .y = 1, .w = 58, .h = 38 }, regions.workbench);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "layouts below the minimum useful sidebar width suppress it" {
    const regions = Regions.calculate(61, 20, true);
    try @import("std").testing.expect(regions.sidebar.isEmpty());
    try @import("std").testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar grows from forty two to sixty two columns" {
    try @import("std").testing.expectEqual(@as(u16, 42), Regions.calculate(62, 20, true).sidebar.w);
    try @import("std").testing.expectEqual(@as(u16, 52), Regions.calculate(72, 20, true).sidebar.w);
    try @import("std").testing.expectEqual(@as(u16, 62), Regions.calculate(120, 20, true).sidebar.w);
}
