const ClientTabLayoutView = @This();
const source_namespace = @import("layout.zig");
const ClientLayoutNodeIterator = @import("ClientLayoutNodeIterator.zig");
location: source_namespace.TabLocation,
focused_pane: source_namespace.PaneId,
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
