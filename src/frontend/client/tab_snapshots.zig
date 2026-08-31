//! Client resource reconciliation after canonical tab snapshots.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_resources = @import("pane_resources.zig");
const request_lifecycle = @import("request_lifecycle.zig");

const Client = @import("client.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const tab_snapshot = client_application.tab_snapshot;

pub const Outcome = enum {
    applied,
    ignored,
};

/// Consumes one correlated response and applies its canonical pane membership.
///
/// ```zig
/// _ = try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.TabSnapshotView) !Outcome {
    const continuation = request_lifecycle.consume(client, snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    const expected_location = switch (continuation) {
        .tab_snapshot => |location| location,
        .ignored => return .ignored,
        else => return error.UnexpectedTabSnapshot,
    };
    if (!std.meta.eql(expected_location, snapshot.location)) {
        return error.UnexpectedTabSnapshot;
    }

    var pane_ids: [schema.max_panes_per_tab]schema.PaneId = undefined;
    var pane_count: usize = 0;
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        if (pane_count == pane_ids.len) {
            return error.TooManyPanes;
        }

        pane_ids[pane_count] = pane.pane_id;
        pane_count += 1;
    }

    var use_case = reconciliationHandler(client);
    try use_case.execute(.{
        .location = snapshot.location,
        .panes = pane_ids[0..pane_count],
    });

    return .applied;
}

fn reconciliationHandler(client: *Client) tab_snapshot.ApplyTabSnapshotHandler {
    return .{
        .model = &client.model,
        .area = client.view.workbench(),
        .effects = .{
            .context = client,
            .apply = applyReconciliation,
        },
    };
}

fn applyReconciliation(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    for (reconciliation.removed_panes.slice()) |pane_id| {
        request_lifecycle.ignorePane(client, pane_id);
        pane_resources.release(client, pane_id);
    }

    const tab = findTab(client, reconciliation.location) orelse
        return error.UnexpectedTabReconciliation;
    if (!reconciliation.active) {
        return;
    }

    const active = client.model.workspace.active() orelse
        return error.UnexpectedTabReconciliation;
    if (active != tab) {
        return error.UnexpectedTabReconciliation;
    }

    try pane_focus.syncResources(client);
    try pane_geometry.offerAttached(client, &tab.model, client.view.workbench());
    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        if (pane.attached or request_lifecycle.hasPane(client, .attachment, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, client.view.workbench()) orelse
            return error.PaneTooSmall;
        const request_id = try request_lifecycle.nextId(client);
        try request_lifecycle.deliver(client, .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{ .attach_pane = .{
                    .pane_id = pane.id,
                    .location = tab.location,
                } },
            },
            .message = .{ .open_pane = .{
                .request_id = request_id,
                .target = .{ .pane = pane.id },
                .size = size,
                .launch = null,
            } },
        });
    }
}

fn findTab(client: *Client, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = client.model.workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
