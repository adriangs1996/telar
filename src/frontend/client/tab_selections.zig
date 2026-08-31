//! Wires semantic tab selection to one client's disposable resources.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const schema = core.schema;
const select_tab = client_application.select_tab;
const tabs_mod = workspace_capability.tabs;

pub const Target = select_tab.Target;

/// Wires tab selection to snapshot gating and attachment synchronization.
///
/// ```zig
/// var use_case = selectionHandler(client);
/// _ = try use_case.execute(.{ .target = .{ .position = 1 } });
/// ```
pub fn selectionHandler(client: *Client) select_tab.SelectTabHandler {
    return .{
        .model = &client.model,
        .snapshots = .{
            .context = client,
            .pending = tabSnapshotPending,
        },
        .effects = .{
            .context = client,
            .apply = applySelection,
        },
    };
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_snapshot);
}

fn applySelection(context: *anyopaque, selection: client_model.TabSelection) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const workspace = &client.model.workspace;
    const previous = findTab(workspace, selection.previous) orelse return error.UnexpectedTabSelection;
    const selected = findTab(workspace, selection.selected) orelse return error.UnexpectedTabSelection;
    const active = workspace.active() orelse return error.UnexpectedTabSelection;
    if (active != selected) {
        return error.UnexpectedTabSelection;
    }

    try tab_attachments.detach(client, previous.location);

    var visible = selected.model.paneIterator();
    while (visible.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    try pane_focus.syncResources(client);
    try request_lifecycle.requestTabSnapshot(client, selected.location);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
