const RemovedWorkspacePanes = @This();
const source_namespace = @import("types.zig");
const std = @import("std");
pub const capacity = source_namespace.schema.max_tabs_per_workspace * source_namespace.schema.max_panes_per_tab;

items: [capacity]source_namespace.schema.PaneId = undefined,
count: u16 = 0,

pub fn append(panes: *RemovedWorkspacePanes, pane_id: source_namespace.schema.PaneId) void {
    std.debug.assert(panes.count < panes.items.len);
    panes.items[panes.count] = pane_id;
    panes.count += 1;
}

/// Returns pane identities whose tab disappeared during reconciliation.
///
/// ```zig
/// for (reconciliation.removed_panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(panes: *const RemovedWorkspacePanes) []const source_namespace.schema.PaneId {
    return panes.items[0..panes.count];
}
