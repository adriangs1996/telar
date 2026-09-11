const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const max_client_layout_nodes_module = @import("telar-core").max_client_layout_nodes;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const ClientTabLayoutViewType = @import("telar-core").ClientTabLayoutView;
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const StoredTab = @This();

location: TabLocationType,
focused_pane: PaneIdType,
fullscreen: bool,
workspace_active: bool,
nodes: [max_client_layout_nodes_module]ClientLayoutNodeType = undefined,
node_count: u8,

pub fn copy(tab: ClientTabLayoutViewType) !StoredTab {
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

pub fn schemaLayout(tab: *const StoredTab) ClientTabLayoutType {
    return .{
        .location = tab.location,
        .focused_pane = tab.focused_pane,
        .fullscreen = tab.fullscreen,
        .workspace_active = tab.workspace_active,
        .nodes = tab.nodes[0..tab.node_count],
    };
}
