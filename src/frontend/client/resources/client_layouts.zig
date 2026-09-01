//! Synchronizes the reconnectable subset of disposable client layout state.

const std = @import("std");
const core = @import("telar-core");

const Client = @import("../client.zig");
const runtime_transport = @import("../connection/runtime_transport.zig");

const schema = core.schema;

const TabVersion = struct {
    location: schema.TabLocation,
    layout_revision: u64,
};

const Version = struct {
    chrome: u64,
    active_tab: schema.TabLocation,
    tabs: [schema.max_client_layout_tabs]TabVersion = undefined,
    tab_count: u8 = 0,

    fn eql(left: *const Version, right: *const Version) bool {
        if (left.chrome != right.chrome or
            !std.meta.eql(left.active_tab, right.active_tab) or
            left.tab_count != right.tab_count)
        {
            return false;
        }
        for (left.tabs[0..left.tab_count], right.tabs[0..right.tab_count]) |left_tab, right_tab| {
            if (!std.meta.eql(left_tab, right_tab)) {
                return false;
            }
        }

        return true;
    }
};

pub const State = struct {
    snapshot_received: bool = false,
    last_sent: ?Version = null,

    /// Opens layout synchronization after the runtime's one bootstrap
    /// snapshot has been consumed.
    ///
    /// ```zig
    /// state.markSnapshotReceived();
    /// ```
    pub fn markSnapshotReceived(state: *State) !void {
        if (state.snapshot_received) {
            return error.DuplicateClientLayoutSnapshot;
        }

        state.snapshot_received = true;
    }
};

/// Coalesces the complete, canonical layout of the current workspace into the
/// runtime outbox. Tabs without a runtime snapshot are omitted until known.
///
/// ```zig
/// try client_layouts.observe(client);
/// ```
pub fn observe(client: *Client) !void {
    if (!client.client_layouts.snapshot_received) {
        return;
    }

    const version = captureVersion(client) orelse return;
    if (client.client_layouts.last_sent) |last| {
        if (last.eql(&version)) {
            return;
        }
    }

    var nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    var tabs: [schema.max_client_layout_tabs]schema.ClientTabLayout = undefined;
    const update = buildUpdate(client, &nodes, &tabs) orelse return;
    runtime_transport.enqueueClientLayout(client, update) catch |err| switch (err) {
        error.ClientOutboxFull, error.TooManyPendingClientLayouts => return,
        else => return err,
    };

    client.client_layouts.last_sent = version;
}

fn captureVersion(client: *Client) ?Version {
    const active_tab = client.model.activeTabLocation() orelse return null;
    var version: Version = .{
        .chrome = client.model.version().chrome,
        .active_tab = active_tab,
    };
    var tabs = client.model.workspace.tabIterator();
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

fn buildUpdate(client: *Client, nodes: *[schema.max_client_layout_nodes]schema.ClientLayoutNode, output: *[schema.max_client_layout_tabs]schema.ClientTabLayout) ?schema.ClientLayoutUpdate {
    const active_tab = client.model.activeTabLocation() orelse return null;
    var scratch: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    var node_count: usize = 0;
    var tab_count: usize = 0;
    var active_included = false;
    var tabs = client.model.workspace.tabIterator();
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
        .sidebar_visible = client.model.sidebarVisible(),
        .sidebar_width = client.model.sidebarWidth(),
        .workspace_list_collapsed = client.model.workspaceListCollapsed(),
        .active_tab = active_tab,
        .tabs = output[0..tab_count],
    };
}
