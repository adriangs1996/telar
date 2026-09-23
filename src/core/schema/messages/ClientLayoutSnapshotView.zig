const TabLocation = @import("../TabLocation.zig");
const ClientTabLayoutIterator = @import("ClientTabLayoutIterator.zig");
const ClientLayoutSnapshotView = @This();

restored: bool,
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
active_tab: ?TabLocation,
tab_count: u16,
encoded_tabs: []const u8,

/// Iterates the runtime-retained tab layouts in this bootstrap snapshot.
///
/// ```zig
/// var tabs = snapshot.tabs();
/// while (try tabs.next()) |tab| restore(tab);
/// ```
pub fn tabs(self: ClientLayoutSnapshotView) ClientTabLayoutIterator {
    return .{ .decoder = .init(self.encoded_tabs), .remaining = self.tab_count };
}
