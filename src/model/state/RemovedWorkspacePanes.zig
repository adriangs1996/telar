const core = @import("telar-core");
const std = @import("std");
const RemovedWorkspacePanes = @This();

pub const capacity = core.max_tabs_per_workspace * core.max_panes_per_tab;

items: [capacity]core.PaneId = undefined,
count: u16 = 0,

pub fn append(self: *RemovedWorkspacePanes, pane_id: core.PaneId) void {
    std.debug.assert(self.count < self.items.len);
    self.items[self.count] = pane_id;
    self.count += 1;
}

/// Returns pane identities whose tab disappeared during reconciliation.
///
/// ```zig
/// for (reconciliation.removed_panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(self: *const RemovedWorkspacePanes) []const core.PaneId {
    return self.items[0..self.count];
}
