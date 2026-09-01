//! Wires tab-close and tab-removal use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const tabs_application = @import("application/tabs/root.zig");
const client_model = @import("model.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");

const Client = @import("client.zig");
const close_tab = tabs_application.close_tab;
const runtime_transport = @import("runtime_transport.zig");
const schema = core.schema;
const tab_removal_delivery = tabs_application.tab_removal_delivery;
const tab_snapshot_recovery = tabs_application.tab_snapshot_recovery;

pub const Outcome = enum {
    applied,
    ignored,
    exit,
};

/// Wires an interactive close to bounded delivery and provisional attachment
/// recovery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute()) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) close_tab.RequestCloseTabHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .preparation = .{
            .requests = .{
                .context = client,
                .ensure = ensureCloseRequests,
            },
            .deliveries = .{
                .context = client,
                .available = availableDeliveryCapacity,
            },
            .pending_attachments = .{
                .context = client,
                .pending = attachmentPending,
            },
        },
        .snapshots = snapshotRecovery(client),
        .effects = .{
            .context = client,
            .detach = detachForClose,
            .send = sendClose,
        },
    };
}

/// Wires close-request rejection to canonical attachment recovery.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(location);
/// ```
pub fn recoveryHandler(client: *Client) close_tab.RecoverCloseTabHandler {
    return .{
        .model = &client.model,
        .snapshots = snapshotRecovery(client),
    };
}

fn snapshotRecovery(client: *Client) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
    return .{ .effects = .{
        .context = client,
        .pending = tabSnapshotPending,
        .request = requestTabSnapshot,
    } };
}

/// Consumes one explicit response or applies one autonomous lifecycle removal.
///
/// ```zig
/// const outcome = try apply(client, closed);
/// ```
pub fn apply(client: *Client, closed: schema.TabClosed) !Outcome {
    const trigger: close_tab.RemovalTrigger = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = request_lifecycle.consume(client, closed.request_id) orelse
            return error.UnexpectedTabClosed;
        const expected_location = switch (continuation) {
            .close_tab => |location| location,
            .ignored => return .ignored,
            else => return error.UnexpectedTabClosed,
        };
        if (!std.meta.eql(expected_location, closed.location)) {
            return error.UnexpectedTabClosed;
        }

        break :requested .requested;
    };

    var use_case = removalHandler(client);
    const directive = try use_case.execute(.{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    });

    return switch (directive) {
        .continue_running => .applied,
        .exit => .exit,
    };
}

fn removalHandler(client: *Client) close_tab.ApplyTabRemovalHandler {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverRemoval,
        },
    };
}

fn deliverRemoval(context: *anyopaque, commit: client_model.TabRemovalCommit, previous_workspace: ?schema.WorkspaceId) !close_tab.TabRemovalDirective {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: tab_removal_delivery.DeliverTabRemovalHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .retire_tab_requests = retireTabRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .tab_snapshot_pending = tabSnapshotPending,
            .request_tab_snapshot = requestTabSnapshot,
            .forget_workspace = forgetWorkspace,
            .request_workspace = requestWorkspace,
        },
    };

    return use_case.execute(commit, previous_workspace);
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn ensureCloseRequests(context: *anyopaque, count: u64) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.ensureCanStart(client, count);
}

fn availableDeliveryCapacity(context: *anyopaque) usize {
    const client: *Client = @ptrCast(@alignCast(context));

    return runtime_transport.availableCapacity(client);
}

fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn detachForClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try tab_attachments.detach(client, location);
}

fn sendClose(context: *anyopaque, intent: close_tab.TabCloseIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);

    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .close_tab = intent.location },
        },
        .message = .{ .close_tab = .{
            .request_id = request_id,
            .location = intent.location,
        } },
    });
}

fn retireTabRequests(context: *anyopaque, location: schema.TabLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    request_lifecycle.ignoreTab(client, location.tab_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(workspace);
}

fn requestWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = try workspace_handoffs.followWorkspace(client, workspace);
}
