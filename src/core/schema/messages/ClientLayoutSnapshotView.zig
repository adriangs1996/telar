const TabLocationType = @import("../TabLocation.zig");
const ClientTabLayoutIterator = @import("ClientTabLayoutIterator.zig");
const ClientLayoutSnapshotView = @This();

restored: bool,
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
active_tab: ?TabLocationType,
tab_count: u16,
encoded_tabs: []const u8,

/// Iterates the runtime-retained tab layouts in this bootstrap snapshot.
///
/// ```zig
/// var tabs = snapshot.tabs();
/// while (try tabs.next()) |tab| restore(tab);
/// ```
pub fn tabs(snapshot: ClientLayoutSnapshotView) ClientTabLayoutIterator {
    return .{ .decoder = .init(snapshot.encoded_tabs), .remaining = snapshot.tab_count };
}
