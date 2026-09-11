const RemovedPanes = @This();
const source_namespace = @import("types.zig");
const std = @import("std");
items: [source_namespace.schema.max_panes_per_tab]source_namespace.schema.PaneId = undefined,
count: u8 = 0,

pub fn append(panes: *RemovedPanes, pane_id: source_namespace.schema.PaneId) void {
    std.debug.assert(panes.count < panes.items.len);
    panes.items[panes.count] = pane_id;
    panes.count += 1;
}

/// Returns pane identities retired by a canonical model transition.
///
/// ```zig
/// for (removal.panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(panes: *const RemovedPanes) []const source_namespace.schema.PaneId {
    return panes.items[0..panes.count];
}
