//! Pane split: asks the runtime for a new pane beside another and commits the
//! split when it arrives.
const data = @import("model");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_focus = @import("pane_focus.zig");
const pane_resize = @import("pane_resize.zig");
const workspace_list_snapshot = @import("../workspace/workspace_list_snapshot.zig");
const Client = @import("../execution/Client.zig");

const SplitRecovery = enum { restored, not_required, stale };

/// Requests creation without committing layout; restores geometry if delivery fails.
/// Example: `_ = try pane_split.requestPaneSplit(client, .{ .axis = .horizontal, .area = self.geometry().area });`
pub fn requestPaneSplit(client: *Client, command: data.RequestPaneSplit) !?data.PaneSplitPlan {
    if (client.model.request_lifecycle.tracker.has(.pane_operation)) {
        return null;
    }

    const plan = client.model.planPaneSplit(command) orelse return null;
    client.model.to_runtime.push(
        .{
            .pane_resize = plan.provisional_resize,
        },
    ) catch |err| {
        try client.model.to_runtime.push(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };

    sendPaneSplitRequest(client, plan) catch |err| {
        try client.model.to_runtime.push(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };

    return plan;
}

fn sendPaneSplitRequest(client: *Client, plan: data.PaneSplitPlan) !void {
    const request_id = try client.model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        &client.model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .split = .{
                        .target_pane = plan.split.target_pane,
                        .location = plan.split.location,
                        .axis = plan.split.axis,
                        .area = plan.split.area,
                    },
                },
            },
            .message = .{
                .create_pane = .{
                    .request_id = request_id,
                    .location = plan.split.location,
                    .size = plan.new_pane_size,
                    .launch = .{
                        .cwd = client.options.cwd,
                        .cwd_source = plan.split.target_pane,
                        .arguments = if (plan.arguments.len != 0) plan.arguments else client.options.arguments,
                    },
                },
            },
        },
    );
}

/// Adopts only the exact runtime reply. Apply effects immediately after the
/// commit, without exposing a second API that accepts potentially stale commits.
/// Runtime correlation supplies the exact pending split before committing it.
pub fn confirmPaneSplit(client: *Client, command: data.ConfirmPaneSplit) !data.PaneSplitCommit {
    if (!command.created or command.confirmed_pane == command.requested.target_pane or
        !std.meta.eql(command.confirmed_location, command.requested.location))
    {
        return error.UnexpectedPane;
    }

    const commit = try client.model.commitPaneSplit(
        .{
            .split = command.requested,
            .new_pane = command.confirmed_pane,
        },
    );
    switch (commit.disposition) {
        .active => {
            const tab = client.model.tabs.find(commit.location.tab_id).?;
            try pane_resize.resizeAttachedPanes(client, tab, commit.area);
            try pane_focus.synchronizeActivePane(client);
        },
        .inactive => {
            try client.model.to_runtime.push(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            try client.graphics.setPaneVisible(commit.pane_id, false);
        },
        .stale => {
            // A late reply may reference an identity now represented elsewhere.
            // Never detach a pane belonging to the current workspace view.
            if (client.model.panes.find(commit.pane_id) != null) {
                return error.StalePaneSplitConfirmation;
            }

            try client.model.to_runtime.push(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            if (client.model.workspace) |workspace| {
                if (std.meta.eql(workspace, commit.location.workspace) and !client.model.request_lifecycle.tracker.has(.workspace_snapshot)) {
                    try workspace_list_snapshot.requestWorkspaceSnapshot(&client.model, workspace);
                }
            }
        },
    }

    return commit;
}

/// Restores only the still-active requested target. A retired target is stale;
/// a target in an inactive tab is already detached and needs no resize.
/// A rejected request restores the active target before the failure notice.
pub fn recoverPaneSplit(model: *data.ClientModel, split: data.PaneSplit) !SplitRecovery {
    return switch (model.recoverPaneSplit(
        .{
            .split = split,
            .area = data.workbench.region(model).area,
        },
    )) {
        .resize => |resize| recovery: {
            try model.to_runtime.push(
                .{
                    .pane_resize = resize,
                },
            );
            break :recovery .restored;
        },
        .not_required => .not_required,
        .stale => .stale,
    };
}
