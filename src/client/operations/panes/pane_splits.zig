//! A split's complete client lifecycle: request, runtime confirmation and recovery.
//! The runtime owns creation; this client owns the requested tab and layout.
const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const RequestPaneSplit = @import("../../model/RequestPaneSplit.zig");
const PaneSplit = @import("../../model/PaneSplit.zig");
const PaneSplitPlan = @import("../../model/PaneSplitPlan.zig");
const PaneSplitCommit = @import("../../model/PaneSplitCommit.zig");
const ConfirmPaneSplit = @import("ConfirmPaneSplit.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const active_pane_resources = @import("active_pane_resources.zig");

pub const Recovery = enum { restored, not_required, stale };

/// Keeps layout unchanged until confirmation. A local delivery failure restores
/// the target's original size, including failures to register the request.
/// Example: `_ = try request(client, .{ .axis = .horizontal, .area = client.geometry().area });`
pub fn request(client: *Client, command: RequestPaneSplit) !?PaneSplitPlan {
    if (request_lifecycle.has(client, .pane_operation)) {
        return null;
    }

    const plan = client.model.planPaneSplit(command) orelse return null;
    client.sendRuntime(
        .{
            .pane_resize = plan.provisional_resize,
        },
    ) catch |err| {
        try client.sendRuntime(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };
    sendRequest(client, plan) catch |err| {
        try client.sendRuntime(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };

    return plan;
}

fn sendRequest(client: *Client, plan: PaneSplitPlan) !void {
    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .split = .{
                .target_pane = plan.split.target_pane,
                .location = plan.split.location,
                .axis = plan.split.axis,
                .area = plan.split.area,
            } },
        },
        .message = .{ .create_pane = .{
            .request_id = request_id,
            .location = plan.split.location,
            .size = plan.new_pane_size,
            .launch = .{
                .cwd = client.options.cwd,
                .cwd_source = plan.split.target_pane,
                .arguments = if (plan.arguments.len != 0) plan.arguments else client.options.arguments,
            },
        } },
    });
}

/// Adopts only the exact runtime reply. Apply effects immediately after the
/// commit, without exposing a second API that accepts potentially stale commits.
/// Example: `_ = try confirm(client, confirmation);`
pub fn confirm(client: *Client, command: ConfirmPaneSplit) !PaneSplitCommit {
    if (!command.created or command.confirmed_pane == command.requested.target_pane or
        !std.meta.eql(command.confirmed_location, command.requested.location))
    {
        return error.UnexpectedPane;
    }

    const commit = try client.model.commitPaneSplit(.{
        .split = command.requested,
        .new_pane = command.confirmed_pane,
    });
    switch (commit.disposition) {
        .active => {
            const tab = client.model.workspace.find(commit.location.tab_id).?;
            try client.resizeAttachedPanes(&tab.model, commit.area);
            try active_pane_resources.synchronize(client);
        },
        .inactive => {
            try client.sendRuntime(
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
            if (client.model.workspace.findPane(commit.pane_id) != null) {
                return error.StalePaneSplitConfirmation;
            }

            try client.sendRuntime(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            if (client.model.workspace.workspace) |workspace| {
                if (std.meta.eql(workspace, commit.location.workspace) and !request_lifecycle.has(client, .workspace_snapshot)) {
                    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
                }
            }
        },
    }

    return commit;
}

/// Restores only the still-active requested target. A retired target is stale;
/// a target in an inactive tab is already detached and needs no resize.
/// Example: `const outcome = try recover(client, split);`
pub fn recover(client: *Client, split: PaneSplit) !Recovery {
    return switch (client.model.recoverPaneSplit(.{ .split = split, .area = client.geometry().area })) {
        .resize => |resize| recovery: {
            try client.sendRuntime(
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
