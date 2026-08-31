//! Wires pane-split application ports to one disposable client.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const pane_geometry = @import("pane_geometry.zig");
const request_lifecycle = @import("request_lifecycle.zig");

const Client = @import("client.zig");
const runtime_transport = @import("runtime_transport.zig");
const schema = core.schema;
const split_pane = client_application.split_pane;
const tabs_mod = workspace_capability.tabs;

/// Wires an interactive split request to provisional resize and delivery.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn requestHandler(client: *Client) split_pane.RequestPaneSplitHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = paneOperationPending,
        },
        .effects = .{
            .context = client,
            .resize = resizePane,
            .send = sendSplit,
        },
    };
}

/// Wires a correlated runtime confirmation to model and client-resource sync.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) split_pane.ConfirmPaneSplitHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyConfirmation,
        },
    };
}

/// Wires a rejected split to exact-target size recovery.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(split);
/// ```
pub fn recoveryHandler(client: *Client) split_pane.RecoverPaneSplitHandler {
    return .{
        .model = &client.model,
        .area = client.view.workbench(),
        .effects = .{
            .context = client,
            .resize = resizePane,
        },
    };
}

fn paneOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .pane_operation);
}

fn resizePane(context: *anyopaque, resize: client_model.PaneResize) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.enqueue(client, .{ .pane_resize = .{
        .pane_id = resize.pane_id,
        .size = resize.size,
    } });
}

fn sendSplit(context: *anyopaque, plan: client_model.PaneSplitPlan) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
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
                .arguments = client.options.arguments,
            },
        } },
    });
}

fn applyConfirmation(context: *anyopaque, commit: client_model.PaneSplitCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    switch (commit.disposition) {
        .active => {
            const tab = findTab(&client.model.workspace, commit.location) orelse
                return error.UnexpectedPaneSplit;
            const active = client.model.workspace.active() orelse
                return error.UnexpectedPaneSplit;
            if (active != tab) {
                return error.UnexpectedPaneSplit;
            }

            try pane_geometry.offerAttached(client, &tab.model, client.view.workbench());
            try active_pane_resources.synchronize(client);
        },
        .inactive => {
            const tab = findTab(&client.model.workspace, commit.location) orelse
                return error.UnexpectedPaneSplit;
            if (client.model.workspace.active()) |active| {
                if (active == tab) {
                    return error.UnexpectedPaneSplit;
                }
            }

            try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = commit.pane_id } });
            try client.graphics_store.setPaneVisible(commit.pane_id, false);
        },
        .stale => {
            try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = commit.pane_id } });
            const workspace = client.model.workspace.workspace orelse return;
            if (!std.meta.eql(workspace, commit.location.workspace) or
                request_lifecycle.has(client, .workspace_snapshot))
            {
                return;
            }

            try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
        },
    }
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
