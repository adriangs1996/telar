//! Wires tab-close and tab-removal use cases to one client's protocol state.

const Client = @import("../../AttachedClient.zig");
const RequestCloseTabHandlerType = @import("../../application/tabs/RequestCloseTabHandler.zig");
const RecoverCloseTabHandlerType = @import("../../application/tabs/RecoverCloseTabHandler.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("../../application/tabs/RequestTabSnapshotRecoveryHandler.zig");
const TabClosedType = @import("telar-core").TabClosed;
const RemovalTriggerType = @import("../../application/tabs/close_tab.zig").RemovalTrigger;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const ApplyTabRemovalHandlerType = @import("../../application/tabs/ApplyTabRemovalHandler.zig");
const TabRemovalCommitType = @import("../../model/types.zig").TabRemovalCommit;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TabRemovalDirectiveType = @import("../../application/tabs/close_tab.zig").TabRemovalDirective;
const DeliverTabRemovalHandlerType = @import("../../application/tabs/DeliverTabRemovalHandler.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const tab_attachments = @import("tab_attachments.zig");
const TabCloseIntentType = @import("../../application/tabs/TabCloseIntent.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

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
pub fn requestHandler(client: *Client) RequestCloseTabHandlerType {
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
pub fn recoveryHandler(client: *Client) RecoverCloseTabHandlerType {
    return .{
        .model = &client.model,
        .snapshots = snapshotRecovery(client),
    };
}

fn snapshotRecovery(client: *Client) RequestTabSnapshotRecoveryHandlerType {
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
pub fn apply(client: *Client, closed: TabClosedType) !Outcome {
    const trigger: RemovalTriggerType = if (closed.request_id == .none)
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

fn removalHandler(client: *Client) ApplyTabRemovalHandlerType {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverRemoval,
        },
    };
}

fn deliverRemoval(context: *anyopaque, commit: TabRemovalCommitType, previous_workspace: ?WorkspaceIdType) !TabRemovalDirectiveType {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverTabRemovalHandlerType = .{
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

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn detachForClose(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try tab_attachments.detach(client, location);
}

fn sendClose(context: *anyopaque, intent: TabCloseIntentType) !void {
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

fn retireTabRequests(context: *anyopaque, location: TabLocationType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    request_lifecycle.ignoreTab(client, location.tab_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}

fn forgetWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(workspace);
}

fn requestWorkspace(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = try workspace_handoffs.followWorkspace(client, workspace);
}
