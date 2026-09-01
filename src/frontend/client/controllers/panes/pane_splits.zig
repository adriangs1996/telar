//! Wires pane-split application ports to one disposable client.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model/root.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const pane_geometry = @import("pane_geometry.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const Client = @import("../../client.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");
const schema = core.schema;
const split_pane = panes_application.split_pane;
const split_confirmation_delivery = panes_application.pane_split_confirmation_delivery;

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

fn deliverConfirmation(context: *anyopaque, commit: client_model.PaneSplitCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: split_confirmation_delivery.DeliverPaneSplitConfirmationHandler = .{
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

fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = pane_id } });
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn workspaceSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .workspace_snapshot);
}

fn requestWorkspaceSnapshot(context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}
