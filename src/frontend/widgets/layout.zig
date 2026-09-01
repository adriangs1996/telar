//! Geometry contract for the client chrome.

const ui = @import("../ui/root.zig");

pub const minimum_sidebar_width: u16 = 42;
pub const sidebar_width: u16 = 62;
pub const minimum_workbench_width: u16 = 20;
pub const attachment_shelf_height: u16 = 6;
const minimum_workbench_height_with_attachments: u16 = 3;

pub const Regions = struct {
    full: ui.Rect,
    top: ui.Rect,
    body: ui.Rect,
    sidebar: ui.Rect,
    workbench: ui.Rect,
    attachments: ui.Rect,
    bottom: ui.Rect,

    pub fn calculate(width: u16, height: u16, sidebar_requested: bool) Regions {
        const full: ui.Rect = .{ .w = width, .h = height };
        const top_height: u16 = @intFromBool(height != 0);
        const bottom_height: u16 = @intFromBool(height >= 2);
        const can_show_sidebar = sidebar_requested and
            full.w >= minimum_workbench_width + minimum_sidebar_width;
        const requested_width = @min(sidebar_width, full.w -| minimum_workbench_width);
        const actual_width: u16 = if (can_show_sidebar) requested_width else 0;
        const sidebar, const client = full.splitLeft(actual_width);
        const top, const below_top = client.splitTop(top_height);
        const body, const bottom = below_top.splitBottom(bottom_height);

        return .{
            .full = full,
            .top = top,
            .body = body,
            .sidebar = sidebar,
            .workbench = body,
            .attachments = .{ .x = body.x, .y = body.y + body.h },
            .bottom = bottom,
        };
    }

    pub fn reserveAttachments(regions: *Regions, visible: bool) void {
        regions.attachments = .{
            .x = regions.workbench.x,
            .y = regions.workbench.y + regions.workbench.h,
        };
        if (!visible) return;
        const available = regions.workbench.h -| minimum_workbench_height_with_attachments;
        const height = @min(attachment_shelf_height, available);
        if (height < 3) return;
        regions.workbench, regions.attachments = regions.workbench.splitBottom(height);
    }
};

test "regions expose the complete chrome layout" {
    const regions = Regions.calculate(120, 40, true);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 62, .w = 58, .h = 1 }, regions.top);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 62, .h = 40 }, regions.sidebar);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 62, .y = 1, .w = 58, .h = 38 }, regions.workbench);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 62, .y = 39, .w = 58, .h = 1 }, regions.bottom);
}

test "hiding the sidebar expands both bars to the full client width" {
    const regions = Regions.calculate(120, 40, false);

    try @import("std").testing.expectEqual(ui.Rect{ .w = 120, .h = 1 }, regions.top);
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

test "attachment shelf reserves pane rows without crossing chrome" {
    var regions = Regions.calculate(120, 40, true);
    regions.reserveAttachments(true);
    try @import("std").testing.expectEqual(@as(u16, 32), regions.workbench.h);
    try @import("std").testing.expectEqual(ui.Rect{
        .x = 62,
        .y = 33,
        .w = 58,
        .h = 6,
    }, regions.attachments);
    try @import("std").testing.expectEqual(regions.bottom.y, regions.attachments.y + regions.attachments.h);
}
