//! Geometry contract for the client chrome.

const ui = @import("../ui/root.zig");
pub const sidebar_geometry = ui.sidebar;

pub const minimum_sidebar_width = sidebar_geometry.minimum_width;
pub const sidebar_width = sidebar_geometry.default_width;
pub const minimum_workbench_width = sidebar_geometry.minimum_workbench_width;

pub const Sidebar = @import("LayoutSidebar.zig");

pub const Regions = @import("LayoutRegions.zig");

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
