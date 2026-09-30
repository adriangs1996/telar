//! Captures layout versions and serializes model state into caller-owned buffers.
const data = @import("model");
const core = @import("telar-core");

const std = @import("std");

/// Captures revisions of loaded tabs; an empty workspace has no export.
/// Example: `const version = client_layouts.captureVersion(model) orelse return;`
pub fn captureVersion(model: *data.ClientModel) ?data.LayoutSyncVersion {
    const active_tab = model.activeTabLocation() orelse return null;
    var version: data.LayoutSyncVersion = .{
        .chrome = model.chrome_revision,
        .active_tab = active_tab,
    };
    for (0..model.tabs.count) |tab| {
        if (!model.tabs.snapshot_loaded[tab]) {
            continue;
        }

        version.tabs[version.tab_count] = .{
            .location = model.tabs.location[tab],
            .layout_revision = model.tabs.layout[tab].currentRevision(),
        };
        version.tab_count += 1;
    }
    if (version.tab_count == 0) {
        return null;
    }

    return version;
}

/// Writes a bounded layout snapshot into caller-owned node and tab buffers.
/// Example: `const update = client_layouts.buildUpdate(model, &nodes, &tabs) orelse return;`
pub fn buildUpdate(model: *data.ClientModel, nodes: *[core.max_client_layout_nodes]core.ClientLayoutNode, output: *[data.Tabs.capacity]core.ClientTabLayout) ?core.ClientLayoutUpdate {
    const active_tab = model.activeTabLocation() orelse return null;
    var scratch: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    var node_count: usize = 0;
    var tab_count: usize = 0;
    var active_included = false;
    for (0..model.tabs.count) |tab| {
        if (!model.tabs.snapshot_loaded[tab]) {
            continue;
        }

        const location = model.tabs.location[tab];
        const layout = &model.tabs.layout[tab];
        const focused_pane = layout.focused() orelse continue;
        const encoded = layout.clientLayoutNodes(&scratch);
        if (encoded.len > nodes.len - node_count) {
            return null;
        }

        @memcpy(nodes[node_count..][0..encoded.len], encoded);
        const is_active = std.meta.eql(location, active_tab);
        output[tab_count] = .{
            .location = location,
            .focused_pane = focused_pane,
            .fullscreen = layout.isFullscreen(),
            .workspace_active = is_active,
            .nodes = nodes[node_count..][0..encoded.len],
        };
        node_count += encoded.len;
        tab_count += 1;
        active_included = active_included or is_active;
    }
    if (!active_included) {
        return null;
    }

    return .{
        .sidebar_visible = model.sidebar_visible,
        .sidebar_width = model.sidebar_width,
        .workspace_list_collapsed = model.workspace_list_collapsed,
        .active_tab = active_tab,
        .tabs = output[0..tab_count],
    };
}
