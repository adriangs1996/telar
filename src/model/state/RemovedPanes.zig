const core = @import("telar-core");
const std = @import("std");
const RemovedPanes = @This();

items: [core.max_panes_per_tab]core.PaneId = undefined,
count: u8 = 0,

pub fn append(panes: *RemovedPanes, pane_id: core.PaneId) void {
    std.debug.assert(panes.count < panes.items.len);
    panes.items[panes.count] = pane_id;
    panes.count += 1;
}

/// Returns pane identities retired by a canonical model transition.
///
/// ```zig
/// for (removal.panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(panes: *const RemovedPanes) []const core.PaneId {
    return panes.items[0..panes.count];
}
