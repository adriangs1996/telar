//! Captures layout versions and serializes model state into caller-owned buffers.
const core = @import("telar-core");
const Model = @import("../model/Model.zig");

const Version = @import("Version.zig");
const std = @import("std");

/// Captures revisions of loaded tabs; an empty workspace has no export.
/// Example: `const version = client_layouts.captureVersion(model) orelse return;`
pub fn captureVersion(model: *Model) ?Version {
    const active_tab = model.activeTabLocation() orelse return null;
    var version: Version = .{
        .chrome = model.version().chrome,
        .active_tab = active_tab,
    };
    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        if (!tab.snapshot_loaded) {
            continue;
        }

        version.tabs[version.tab_count] = .{
            .location = tab.location,
            .layout_revision = tab.model.layout.currentRevision(),
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
pub fn buildUpdate(model: *Model, nodes: *[core.max_client_layout_nodes]core.ClientLayoutNode, output: *[core.max_client_layout_tabs]core.ClientTabLayout) ?core.ClientLayoutUpdate {
    const active_tab = model.activeTabLocation() orelse return null;
    var scratch: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    var node_count: usize = 0;
    var tab_count: usize = 0;
    var active_included = false;
    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        if (!tab.snapshot_loaded) {
            continue;
        }

        const focused_pane = tab.model.layout.focused() orelse continue;
        const encoded = tab.model.layout.clientLayoutNodes(&scratch);
        if (encoded.len > nodes.len - node_count) {
            return null;
        }

        @memcpy(nodes[node_count..][0..encoded.len], encoded);
        const is_active = std.meta.eql(tab.location, active_tab);
        output[tab_count] = .{
            .location = tab.location,
            .focused_pane = focused_pane,
            .fullscreen = tab.model.layout.isFullscreen(),
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
        .sidebar_visible = model.sidebarVisible(),
        .sidebar_width = model.sidebarWidth(),
        .workspace_list_collapsed = model.workspaceListCollapsed(),
        .active_tab = active_tab,
        .tabs = output[0..tab_count],
    };
}
