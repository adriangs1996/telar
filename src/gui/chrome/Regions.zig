const core = @import("telar-core");
const client = @import("telar-client");
const SidebarSpec = @import("SidebarSpec.zig");
const Regions = @This();

full: core.Rect,
sidebar: core.Rect,
workbench: core.Rect,

/// Partitions the cell grid between the sidebar column and the workbench.
/// The top bar, the tab strip and the status bar are pixel bands that
/// `TerminalRenderer.measure` subtracts before this grid exists, so every
/// cell here is a complete terminal cell and the PTY never sees chrome.
/// Example: `const regions = Regions.calculate(120, 40, sidebar);`
pub fn calculate(width: u16, height: u16, sidebar_spec: SidebarSpec) Regions {
    const full: core.Rect = .{ .w = width, .h = height };
    const sidebar, const workbench = full.splitLeft(client.actualWidth(width, sidebar_spec.visible, sidebar_spec.preferred_width));

    return .{ .full = full, .sidebar = sidebar, .workbench = workbench };
}
