const StoredTab = @This();
const source_namespace = @import("client_layout_store.zig");
location: source_namespace.schema.TabLocation,
focused_pane: source_namespace.schema.PaneId,
fullscreen: bool,
workspace_active: bool,
nodes: [source_namespace.schema.max_client_layout_nodes]source_namespace.schema.ClientLayoutNode = undefined,
node_count: u8,

pub fn copy(tab: source_namespace.schema.ClientTabLayoutView) !StoredTab {
    var stored: StoredTab = .{
        .location = tab.location,
        .focused_pane = tab.focused_pane,
        .fullscreen = tab.fullscreen,
        .workspace_active = tab.workspace_active,
        .node_count = @intCast(tab.node_count),
    };
    var nodes = tab.nodes();
    var index: usize = 0;
    while (try nodes.next()) |node| : (index += 1) {
        stored.nodes[index] = node;
    }

    return stored;
}

pub fn schemaLayout(tab: *const StoredTab) source_namespace.schema.ClientTabLayout {
    return .{
        .location = tab.location,
        .focused_pane = tab.focused_pane,
        .fullscreen = tab.fullscreen,
        .workspace_active = tab.workspace_active,
        .nodes = tab.nodes[0..tab.node_count],
    };
}
