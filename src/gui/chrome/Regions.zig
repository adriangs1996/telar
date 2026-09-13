const core = @import("telar-core");
const client = @import("telar-client");
const SidebarSpec = @import("SidebarSpec.zig");
const Regions = @This();

full: core.Rect,
top: core.Rect,
sidebar: core.Rect,
workbench: core.Rect,
bottom: core.Rect,

/// Reserves chrome while retaining a terminal row even in a tiny window.
/// Example: `const regions = Regions.calculate(120, 40, sidebar);`
pub fn calculate(width: u16, height: u16, sidebar_spec: SidebarSpec) Regions {
    const full: core.Rect = .{ .w = width, .h = height };
    const sidebar, const body = full.splitLeft(client.actualWidth(width, sidebar_spec.visible, sidebar_spec.preferred_width));
    const top, const below = body.splitTop(@intFromBool(height >= 3));
    const workbench, const bottom = below.splitBottom(@intFromBool(height >= 2));

    return .{ .full = full, .top = top, .sidebar = sidebar, .workbench = workbench, .bottom = bottom };
}
