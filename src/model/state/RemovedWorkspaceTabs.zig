const core = @import("telar-core");
const std = @import("std");
const RemovedWorkspaceTabs = @This();

items: [core.max_tabs_per_workspace]core.TabLocation = undefined,
count: u8 = 0,

pub fn append(tabs: *RemovedWorkspaceTabs, location: core.TabLocation) void {
    std.debug.assert(tabs.count < tabs.items.len);
    tabs.items[tabs.count] = location;
    tabs.count += 1;
}

/// Returns the tab identities absent from the canonical snapshot.
///
/// ```zig
/// for (reconciliation.removed_tabs.slice()) |location| ignore(location);
/// ```
pub fn slice(tabs: *const RemovedWorkspaceTabs) []const core.TabLocation {
    return tabs.items[0..tabs.count];
}
