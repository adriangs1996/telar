const core = @import("telar-core");
const StoredTab = @This();

location: core.TabLocation,
focused_pane: core.PaneId,
fullscreen: bool,
workspace_active: bool,
nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined,
node_count: u8,

pub fn copy(tab: core.ClientTabLayoutView) !StoredTab {
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

pub fn schemaLayout(tab: *const StoredTab) core.ClientTabLayout {
    return .{
        .location = tab.location,
        .focused_pane = tab.focused_pane,
        .fullscreen = tab.fullscreen,
        .workspace_active = tab.workspace_active,
        .nodes = tab.nodes[0..tab.node_count],
    };
}
