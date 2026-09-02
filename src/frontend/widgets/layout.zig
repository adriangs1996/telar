//! Geometry contract for the client chrome.

const ui = @import("../ui/root.zig");
const sidebar_geometry = ui.sidebar;

pub const minimum_sidebar_width = sidebar_geometry.minimum_width;
pub const sidebar_width = sidebar_geometry.default_width;
pub const minimum_workbench_width = sidebar_geometry.minimum_workbench_width;
pub const attachment_shelf_height: u16 = 6;
const minimum_workbench_height_with_attachments: u16 = 3;

pub const Sidebar = struct {
    visible: bool,
    preferred_width: u16,
};

pub const Regions = struct {
    full: ui.Rect,
    top: ui.Rect,
    body: ui.Rect,
    sidebar: ui.Rect,
    workbench: ui.Rect,
    attachments: ui.Rect,
    bottom: ui.Rect,

    pub fn calculate(width: u16, height: u16, sidebar_spec: Sidebar) Regions {
        const full: ui.Rect = .{ .w = width, .h = height };
        const top_height: u16 = @intFromBool(height != 0);
        const bottom_height: u16 = @intFromBool(height >= 2);
        const actual_width = sidebar_geometry.actualWidth(full.w, sidebar_spec.visible, sidebar_spec.preferred_width);
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
    const regions = Regions.calculate(120, 40, .{ .visible = true, .preferred_width = sidebar_width });
    try @import("std").testing.expectEqual(ui.Rect{ .x = 42, .w = 78, .h = 1 }, regions.top);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 42, .h = 40 }, regions.sidebar);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 42, .y = 1, .w = 78, .h = 38 }, regions.workbench);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 42, .y = 39, .w = 78, .h = 1 }, regions.bottom);
}

test "hiding the sidebar expands both bars to the full client width" {
    const regions = Regions.calculate(120, 40, .{ .visible = false, .preferred_width = sidebar_width });

    try @import("std").testing.expectEqual(ui.Rect{ .w = 120, .h = 1 }, regions.top);
    try @import("std").testing.expectEqual(ui.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "layouts below the minimum useful sidebar width suppress it" {
    const regions = Regions.calculate(61, 20, .{ .visible = true, .preferred_width = sidebar_width });
    try @import("std").testing.expect(regions.sidebar.isEmpty());
    try @import("std").testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar starts at its minimum width on every viable host" {
    try @import("std").testing.expectEqual(@as(u16, 42), Regions.calculate(62, 20, .{ .visible = true, .preferred_width = sidebar_width }).sidebar.w);
    try @import("std").testing.expectEqual(@as(u16, 42), Regions.calculate(72, 20, .{ .visible = true, .preferred_width = sidebar_width }).sidebar.w);
    try @import("std").testing.expectEqual(@as(u16, 42), Regions.calculate(120, 20, .{ .visible = true, .preferred_width = sidebar_width }).sidebar.w);
}

test "sidebar honors an arbitrary preferred width" {
    const regions = Regions.calculate(120, 20, .{ .visible = true, .preferred_width = 73 });

    try @import("std").testing.expectEqual(@as(u16, 73), regions.sidebar.w);
    try @import("std").testing.expectEqual(@as(u16, 47), regions.workbench.w);
}

test "attachment shelf reserves pane rows without crossing chrome" {
    var regions = Regions.calculate(120, 40, .{ .visible = true, .preferred_width = sidebar_width });
    regions.reserveAttachments(true);
    try @import("std").testing.expectEqual(@as(u16, 32), regions.workbench.h);
    try @import("std").testing.expectEqual(ui.Rect{
        .x = 42,
        .y = 33,
        .w = 78,
        .h = 6,
    }, regions.attachments);
    try @import("std").testing.expectEqual(regions.bottom.y, regions.attachments.y + regions.attachments.h);
}
