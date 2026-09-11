const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const RemovedWorkspaceTabs = @This();

items: [max_tabs_per_workspace_module]TabLocationType = undefined,
count: u8 = 0,

pub fn append(tabs: *RemovedWorkspaceTabs, location: TabLocationType) void {
    std.debug.assert(tabs.count < tabs.items.len);
    tabs.items[tabs.count] = location;
    tabs.count += 1;
}

/// Returns the tab identities absent from the canonical snapshot.
///
/// ```zig
/// for (reconciliation.removed_tabs.slice()) |location| ignore(location);
/// ```
pub fn slice(tabs: *const RemovedWorkspaceTabs) []const TabLocationType {
    return tabs.items[0..tabs.count];
}
