//! Client layout persistence: sends the reconnectable layout to the runtime
//! and restores it when the client starts.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const layout_updates = @import("../resources/client_layouts.zig");
const client_startup = @import("../connection/client_startup.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const sidebar_toggle = @import("sidebar_toggle.zig");
const Client = @import("../execution/Client.zig");

/// Coalesces the complete, canonical layout of the current workspace into the
/// runtime outbox. Tabs without a runtime snapshot are omitted until known.
/// Example: `try client_layout.synchronizeClientLayout(app);`
pub fn synchronizeClientLayout(model: *data.ClientModel) !void {
    if (!model.client_layouts.snapshot_received) {
        return;
    }

    const version = layout_updates.captureVersion(model) orelse return;
    if (model.client_layouts.last_sent) |last| {
        if (last.eql(&version)) {
            return;
        }
    }

    var nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    var tabs: [data.Tabs.capacity]core.ClientTabLayout = undefined;
    const layout_update = layout_updates.buildUpdate(
        model,
        &nodes,
        &tabs,
    ) orelse return;
    sendRuntimeClientLayout(model, layout_update) catch |err| switch (err) {
        error.ClientOutboxFull, error.TooManyPendingClientLayouts => return,
        else => return err,
    };

    model.client_layouts.last_sent = version;
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try client_layout.sendRuntimeClientLayout(client, update);
/// ```
fn sendRuntimeClientLayout(model: *data.ClientModel, layout_update: core.ClientLayoutUpdate) !void {
    try model.to_runtime.pushClientLayout(layout_update);
}

/// Consumes the single bootstrap snapshot, restores client-owned preferences
/// and sends the initial attach-or-create request with the restored geometry.
pub fn restoreClientLayout(client: *Client, snapshot: core.ClientLayoutSnapshotView) !void {
    if (client.model.client_layouts.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    var saved_layouts: data.SavedLayouts = .{};
    var history: data.NavigationHistory = .{};
    const restored = if (snapshot.restored)
        try parseClientLayoutSnapshot(
            snapshot,
            &saved_layouts,
            &history,
        )
    else
        null;

    if (snapshot.restored) {
        if (data.sidebar.restoreLayout(&client.model, snapshot.sidebar_visible, snapshot.sidebar_width)) |change| {
            try sidebar_toggle.deliverSidebarLayout(client, change);
        }

        _ = data.workspace_list.setCollapsed(&client.model, snapshot.workspace_list_collapsed);

        data.client_layout_persistence.restore(&client.model, saved_layouts);
        client.model.navigation_history = history;
    }

    // A hidden machine's first pane waits until the window shows it, so its
    // runtime streams nothing meanwhile.
    if (!client.presented) {
        client.open_deferred = true;
        client.deferred_layout = restored;
        try client.model.client_layouts.markSnapshotReceived();
        return;
    }

    try openInitialPane(client, restored);
    try client.model.client_layouts.markSnapshotReceived();
}

/// Sends the initial attach-or-create request for the restored layout, or
/// for a new pane when there is none.
///
/// ```zig
/// try client_layout.openInitialPane(client, restored);
/// ```
pub fn openInitialPane(client: *Client, restored: ?data.SavedLayout) !void {
    const size = data.multiplexer.rectSize(client.geometry().area) orelse
        return error.TerminalTooSmall;
    const request = client_startup.initialPaneRequest(client, restored, size);
    try runtime_io.sendRuntimeRequest(&client.model, request);
}

fn parseClientLayoutSnapshot(snapshot: core.ClientLayoutSnapshotView, layouts: *data.SavedLayouts, history: *data.NavigationHistory) !?data.SavedLayout {
    var restored_active: ?data.SavedLayout = null;
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        const saved: data.SavedLayout = .{
            .location = tab.location,
            .pane_id = tab.focused_pane,
            .workspace_active = tab.workspace_active,
            .layout = try data.WorkspaceLayout.fromClientLayout(tab),
        };

        try layouts.remember(saved);
        if (tab.workspace_active) {
            history.remember(
                .{
                    .location = tab.location,
                    .pane_id = tab.focused_pane,
                    .tab_layout = saved.layout,
                },
            );
        }

        if (snapshot.active_tab) |active_location| {
            if (std.meta.eql(tab.location, active_location)) {
                restored_active = saved;
            }
        }
    }

    if (snapshot.active_tab != null and restored_active == null) {
        return error.InvalidClientLayoutActiveTab;
    }

    return restored_active;
}
