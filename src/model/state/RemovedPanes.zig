const core = @import("telar-core");
const std = @import("std");
const RemovedPanes = @This();

items: [core.max_panes_per_tab]core.PaneId = undefined,
count: u8 = 0,

pub fn append(self: *RemovedPanes, pane_id: core.PaneId) void {
    std.debug.assert(self.count < self.items.len);
    self.items[self.count] = pane_id;
    self.count += 1;
}

/// Returns pane identities retired by a canonical model transition.
///
/// ```zig
/// for (removal.panes.slice()) |pane_id| release(pane_id);
/// ```
pub fn slice(self: *const RemovedPanes) []const core.PaneId {
    return self.items[0..self.count];
}
