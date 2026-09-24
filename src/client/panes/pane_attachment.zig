//! Pane attachment: attaches visible panes to the runtime and adopts the panes
//! it opens.
const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const agent_control = @import("../agents/agent_control.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_resize = @import("pane_resize.zig");
const pane_split = @import("pane_split.zig");
const tab_snapshot = @import("../workspace/tab_snapshot.zig");
const workspace_creation = @import("../workspace/workspace_creation.zig");
const Client = @import("../execution/Client.zig");

const PaneOpenOutcome = enum { workspace_arrived, workspace_created, pane_split, pane_attached, ignored };

/// Acknowledges a completed agent and reconciles its focused attachment shelf. Example: `_ = try pane_attachment.synchronizePaneAttachments(client);`
pub fn synchronizePaneAttachments(client: *Client) !bool {
    if (client.model.takeAgentAcknowledgement()) |key| {
        try client.model.to_runtime.push(
            .{
                .acknowledge_agent = .{
                    .pane_id = key.pane_id,
                    .pane_generation = key.pane_generation,
                },
            },
        );
    }

    const shelf = client.attachments orelse return false;
    if (!shelf.syncTarget(client.model.focusedAttachmentTarget())) {
        return false;
    }

    if (client.model.tabs.activeSlot()) |tab| {
        try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
    }

    return true;
}

/// Connects visible detached panes after canonical membership is loaded.
/// Pending attachments are coalesced; failed delivery rolls back its correlation.
/// Example: `if (tab.snapshot_loaded) { try pane_attachment.attachVisiblePanes(client, tab, area); }`
pub fn attachVisiblePanes(model: *data.ClientModel, tab: usize, area: cellgrid.Rect) !void {
    std.debug.assert(model.tabs.snapshot_loaded[tab]);
    var panes = model.panes.iterate(model.tabs.location[tab].tab_id);

    while (panes.next()) |pane| {
        if (pane.attached or model.request_lifecycle.tracker.hasPane(.attachment, pane.id)) {
            continue;
        }

        const size = data.tab_layout.contentSize(model, tab, pane.id, area) orelse continue;
        const request_id = try model.request_lifecycle.nextId();
        try runtime_io.sendRuntimeRequest(
            model,
            .{
                .registration = .{
                    .request_id = request_id,
                    .continuation = .{
                        .attach_pane = .{
                            .pane_id = pane.id,
                            .location = model.tabs.location[tab],
                        },
                    },
                },
                .message = .{
                    .open_pane = .{
                        .request_id = request_id,
                        .target = .{
                            .pane = pane.id,
                        },
                        .size = size,
                        .launch = null,
                    },
                },
            },
        );
    }
}

/// A failed attachment repairs membership only while that pane is still detached.
pub fn recoverPaneAttachment(model: *data.ClientModel, attachment: data.PaneAttachment) !bool {
    if (!model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try tab_snapshot.recoverTabSnapshot(model, attachment.location);
    return true;
}

/// Consumes the request once before applying its confirmation and agent attachment.
pub fn completePaneOpen(client: *Client, opened: core.PaneOpened) !PaneOpenOutcome {
    const continuation = client.model.request_lifecycle.tracker.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    const outcome: PaneOpenOutcome = switch (continuation) {
        .initial_open => result: {
            try workspace_creation.arriveOpenedWorkspace(client, translateOpenedPane(opened));
            break :result .workspace_arrived;
        },
        .create_workspace => |size| result: {
            try workspace_creation.createOpenedWorkspace(
                client,
                .{
                    .opened = translateOpenedPane(opened),
                    .requested_size = size,
                },
            );
            break :result .workspace_created;
        },
        .split => |split| result: {
            _ = try pane_split.confirmPaneSplit(
                client,
                .{
                    .requested = .{
                        .target_pane = split.target_pane,
                        .location = split.location,
                        .axis = split.axis,
                        .area = split.area,
                    },
                    .confirmed_pane = opened.pane_id,
                    .confirmed_location = opened.location,
                    .created = opened.created,
                },
            );
            break :result .pane_split;
        },
        .attach_pane => |attachment| result: {
            try confirmPaneAttachment(
                &client.model,
                .{
                    .requested = .{
                        .pane_id = attachment.pane_id,
                        .location = attachment.location,
                    },
                    .opened = translateOpenedPane(opened),
                },
            );
            break :result .pane_attached;
        },
        .ignored => .ignored,
        else => return error.UnexpectedRequest,
    };

    if (outcome != .ignored) {
        try identifyOpenedPane(&client.model, opened);
    }

    return outcome;
}

fn translateOpenedPane(opened: core.PaneOpened) data.OpenedPane {
    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .created = opened.created,
    };
}

/// Rejects mismatched or newly created panes before committing an attachment.
fn confirmPaneAttachment(model: *data.ClientModel, confirmation: data.PaneAttachmentConfirmation) !void {
    const confirmed: data.PaneAttachment = .{
        .pane_id = confirmation.opened.pane_id,
        .location = confirmation.opened.location,
    };

    if (confirmation.opened.created or !std.meta.eql(confirmation.requested, confirmed)) {
        return error.UnexpectedPane;
    }

    _ = try model.confirmPaneAttachment(confirmed);
}

/// Sets runtime pane identity after the existing attachment flow commits.
fn identifyOpenedPane(model: *data.ClientModel, opened_pane: core.PaneOpened) !void {
    if (model.identifyPane(opened_pane) and opened_pane.kind == .agent) {
        try agent_control.queryAgentThread(model, opened_pane.pane_id);
    }
}
