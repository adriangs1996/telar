//! Wires pane-split application ports to one disposable client.

const Client = @import("../../AttachedClient.zig");
const RequestPaneSplitHandlerType = @import("../../application/panes/RequestPaneSplitHandler.zig");
const ConfirmPaneSplitHandlerType = @import("../../application/panes/ConfirmPaneSplitHandler.zig");
const RecoverPaneSplitHandlerType = @import("../../application/panes/RecoverPaneSplitHandler.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const PaneSplitPlanType = @import("../../model/PaneSplitPlan.zig");
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const DeliverPaneSplitConfirmationHandlerType = @import("../../application/panes/DeliverPaneSplitConfirmationHandler.zig");
const pane_geometry = @import("pane_geometry.zig");
const PaneIdType = @import("telar-core").PaneId;
const active_pane_resources = @import("active_pane_resources.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;

/// Wires an interactive split request to provisional resize and delivery.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn requestHandler(client: *Client) RequestPaneSplitHandlerType {
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
pub fn confirmationHandler(client: *Client) ConfirmPaneSplitHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverConfirmation,
        },
    };
}

/// Wires a rejected split to exact-target size recovery.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(split);
/// ```
pub fn recoveryHandler(client: *Client) RecoverPaneSplitHandlerType {
    return .{
        .model = &client.model,
        .area = client.geometry().area,
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

fn resizePane(context: *anyopaque, resize: PaneResizeType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.enqueue(client, .{ .pane_resize = .{
        .pane_id = resize.pane_id,
        .size = resize.size,
    } });
}

fn sendSplit(context: *anyopaque, plan: PaneSplitPlanType) !void {
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

fn deliverConfirmation(context: *anyopaque, commit: PaneSplitCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverPaneSplitConfirmationHandlerType = .{
        .model = &client.model,
        .geometry_effects = pane_geometry.offerEffects(client),
        .effects = .{
            .context = client,
            .detach_pane = detachPane,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .workspace_snapshot_pending = workspaceSnapshotPending,
            .request_workspace_snapshot = requestWorkspaceSnapshot,
        },
    };

    try use_case.execute(commit);
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = pane_id } });
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn workspaceSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .workspace_snapshot);
}

fn requestWorkspaceSnapshot(context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}
