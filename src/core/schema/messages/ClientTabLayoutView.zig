const TabLocationType = @import("../TabLocation.zig");
const id = @import("../id.zig");
const ClientLayoutNodeIterator = @import("ClientLayoutNodeIterator.zig");
const ClientTabLayoutView = @This();

location: TabLocationType,
focused_pane: id.PaneId,
fullscreen: bool,
workspace_active: bool,
node_count: u16,
encoded_nodes: []const u8,

/// Iterates this validated pre-order split tree without allocating.
///
/// ```zig
/// var nodes = tab.nodes();
/// while (try nodes.next()) |node| use(node);
/// ```
pub fn nodes(layout: ClientTabLayoutView) ClientLayoutNodeIterator {
    return .{ .decoder = .init(layout.encoded_nodes), .remaining = layout.node_count };
}
