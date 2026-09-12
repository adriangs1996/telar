//! Restores the runtime-retained client layout before the initial pane open.

const Client = @import("../../AttachedClient.zig");
const ClientLayoutSnapshotViewType = @import("telar-core").ClientLayoutSnapshotView;
const LayoutsType = @import("../../workspace/Layouts.zig");
const HistoryType = @import("../../workspace/History.zig");
const sidebar_projection = @import("../notifications/sidebar_projection.zig");
const rectSize_module = @import("../../workspace/multiplexer.zig").rectSize;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const SavedLayoutType = @import("../../workspace/SavedLayout.zig");
const LayoutType = @import("../../workspace/WorkspaceLayout.zig");
const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const DeliveryType = @import("../../connection/ConnectionDelivery.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const initial_request_id_module = @import("../../connection/lifecycle.zig").initial_request_id;

/// Consumes the single bootstrap snapshot, restores client-owned preferences
/// and sends the initial attach-or-create request with the restored geometry.
///
/// ```zig
/// try client_layouts.apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: ClientLayoutSnapshotViewType) !void {
    if (client.client_layouts.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    var saved_layouts: LayoutsType = .{};
    var history: HistoryType = .{};
    const restored = if (snapshot.restored)
        try parseSnapshot(snapshot, &saved_layouts, &history)
    else
        null;

    if (snapshot.restored) {
        if (client.model.restoreSidebarLayout(snapshot.sidebar_visible, snapshot.sidebar_width)) |change| {
            try sidebar_projection.apply(client, change);
        }
        if (client.model.setWorkspaceListCollapsed(snapshot.workspace_list_collapsed)) |_| {
            client.chrome.setWorkspaceListCollapsed(snapshot.workspace_list_collapsed);
        }

        client.model.restoreClientLayouts(saved_layouts);
        client.navigation_history = history;
    }

    const size = rectSize_module(client.geometry().area) orelse
        return error.TerminalTooSmall;
    const request = initialRequest(client, restored, size);
    try request_lifecycle.deliver(client, request);
    try client.client_layouts.markSnapshotReceived();
}

fn parseSnapshot(snapshot: ClientLayoutSnapshotViewType, layouts: *LayoutsType, history: *HistoryType) !?SavedLayoutType {
    var restored_active: ?SavedLayoutType = null;
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        const saved: SavedLayoutType = .{
            .location = tab.location,
            .pane_id = tab.focused_pane,
            .workspace_active = tab.workspace_active,
            .layout = try LayoutType.fromClientLayout(tab),
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

fn initialRequest(client: *Client, restored: ?SavedLayoutType, size: TerminalSizeType) DeliveryType {
    const fallback_workspace: ?WorkspaceIdType = if (restored) |saved| switch (saved.location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => null,
    } else null;

    return .{
        .registration = .{
            .request_id = initial_request_id_module,
            .continuation = .{ .initial_open = .{ .fallback_workspace = fallback_workspace } },
        },
        .message = .{ .open_pane = .{
            .request_id = initial_request_id_module,
            .target = if (restored) |saved| .{ .pane = saved.pane_id } else .default,
            .size = size,
            .launch = if (restored == null) .{
                .cwd = client.options.cwd,
                .arguments = client.options.arguments,
            } else null,
        } },
    };
}
