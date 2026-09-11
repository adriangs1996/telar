const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const RemovedWorkspacePanes = @This();

pub const capacity = max_tabs_per_workspace_module * max_panes_per_tab_module;

items: [capacity]PaneIdType = undefined,
count: u16 = 0,

pub fn append(panes: *RemovedWorkspacePanes, pane_id: PaneIdType) void {
    std.debug.assert(panes.count < panes.items.len);
    panes.items[panes.count] = pane_id;
    panes.count += 1;
}

/// Returns pane identities whose tab disappeared during reconciliation.
///
/// ```zig
/// for (reconciliation.removed_panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(panes: *const RemovedWorkspacePanes) []const PaneIdType {
    return panes.items[0..panes.count];
}
