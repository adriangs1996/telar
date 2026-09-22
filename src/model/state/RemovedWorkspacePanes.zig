const core = @import("telar-core");
const std = @import("std");
const RemovedWorkspacePanes = @This();

pub const capacity = core.max_tabs_per_workspace * core.max_panes_per_tab;

items: [capacity]core.PaneId = undefined,
count: u16 = 0,

pub fn append(panes: *RemovedWorkspacePanes, pane_id: core.PaneId) void {
    std.debug.assert(panes.count < panes.items.len);
    panes.items[panes.count] = pane_id;
    panes.count += 1;
}

/// Returns pane identities whose tab disappeared during reconciliation.
///
/// ```zig
/// for (reconciliation.removed_panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(panes: *const RemovedWorkspacePanes) []const core.PaneId {
    return panes.items[0..panes.count];
}
