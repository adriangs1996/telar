//! Restores the runtime-retained client layout before the initial pane open.

const std = @import("std");
const core = @import("telar-core");
const workspace = @import("../../../workspace/root.zig");

const Client = @import("../../client.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const sidebar_projection = @import("../notifications/sidebar_projection.zig");

const navigation = workspace.navigation;
const schema = core.schema;

/// Consumes the single bootstrap snapshot, restores client-owned preferences
/// and sends the initial attach-or-create request with the restored geometry.
///
/// ```zig
/// try client_layouts.apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.ClientLayoutSnapshotView) !void {
    if (client.client_layouts.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    var saved_layouts: navigation.Layouts = .{};
    var history: navigation.History = .{};
    const restored = if (snapshot.restored)
        try parseSnapshot(snapshot, &saved_layouts, &history)
    else
        null;

    if (snapshot.restored) {
        if (client.model.restoreSidebarLayout(snapshot.sidebar_visible, snapshot.sidebar_width)) |change| {
            try sidebar_projection.apply(client, change);
        }
        if (client.model.setWorkspaceListCollapsed(snapshot.workspace_list_collapsed)) |_| {
            client.view.setWorkspaceListCollapsed(snapshot.workspace_list_collapsed);
        }

        client.saved_layouts = saved_layouts;
        client.navigation_history = history;
    }

    const size = workspace.multiplexer.rectSize(client.view.workbench()) orelse
        return error.TerminalTooSmall;
    const request = initialRequest(client, restored, size);
    try request_lifecycle.deliver(client, request);
    try client.client_layouts.markSnapshotReceived();
}

fn parseSnapshot(snapshot: schema.ClientLayoutSnapshotView, layouts: *navigation.Layouts, history: *navigation.History) !?navigation.SavedLayout {
    var restored_active: ?navigation.SavedLayout = null;
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        const saved: navigation.SavedLayout = .{
            .location = tab.location,
            .pane_id = tab.focused_pane,
            .workspace_active = tab.workspace_active,
            .layout = try workspace.layout.Layout.fromClientLayout(tab),
        };
        try layouts.remember(saved);
        if (tab.workspace_active) {
            history.remember(.{
                .location = tab.location,
                .pane_id = tab.focused_pane,
                .tab_layout = saved.layout,
            });
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

fn initialRequest(client: *Client, restored: ?navigation.SavedLayout, size: schema.TerminalSize) request_lifecycle.Delivery {
    const fallback_workspace: ?schema.WorkspaceId = if (restored) |saved| switch (saved.location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => null,
    } else null;

    return .{
        .registration = .{
            .request_id = request_lifecycle.initial_request_id,
            .continuation = .{ .initial_open = .{ .fallback_workspace = fallback_workspace } },
        },
        .message = .{ .open_pane = .{
            .request_id = request_lifecycle.initial_request_id,
            .target = if (restored) |saved| .{ .pane = saved.pane_id } else .default,
            .size = size,
            .launch = if (restored == null) .{
                .cwd = client.options.cwd,
                .arguments = client.options.arguments,
            } else null,
        } },
    };
}
