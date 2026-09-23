const core = @import("telar-core");
const std = @import("std");
const RemovedWorkspaceTabs = @This();

items: [core.max_tabs_per_workspace]core.TabLocation = undefined,
count: u8 = 0,

pub fn append(self: *RemovedWorkspaceTabs, location: core.TabLocation) void {
    std.debug.assert(self.count < self.items.len);
    self.items[self.count] = location;
    self.count += 1;
}

/// Returns the tab identities absent from the canonical snapshot.
///
/// ```zig
/// for (reconciliation.removed_tabs.slice()) |location| ignore(location);
/// ```
pub fn slice(self: *const RemovedWorkspaceTabs) []const core.TabLocation {
    return self.items[0..self.count];
}
