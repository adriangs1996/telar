const RemovedWorkspaceTabs = @This();
const source_namespace = @import("types.zig");
const std = @import("std");
items: [source_namespace.schema.max_tabs_per_workspace]source_namespace.schema.TabLocation = undefined,
count: u8 = 0,

pub fn append(tabs: *RemovedWorkspaceTabs, location: source_namespace.schema.TabLocation) void {
    std.debug.assert(tabs.count < tabs.items.len);
    tabs.items[tabs.count] = location;
    tabs.count += 1;
}

/// Returns the tab identities absent from the canonical snapshot.
///
/// ```zig
/// for (reconciliation.removed_tabs.slice()) |location| ignore(location);
/// ```
pub fn slice(tabs: *const RemovedWorkspaceTabs) []const source_namespace.schema.TabLocation {
    return tabs.items[0..tabs.count];
}
