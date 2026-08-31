//! Reconciliation of every message the runtime sends: the dispatcher and
//! one named entrypoint per message, operating on the client the way the
//! input handler does. Nothing here owns state — the client does; this
//! file owns the protocol conversation.

const std = @import("std");
const core = @import("telar-core");
const graphics = @import("../graphics/root.zig");
const presentation = @import("../presentation/root.zig");
const client_requests = @import("requests.zig");
const widgets = @import("../widgets/root.zig");
const term = presentation.screen;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const client_mod = @import("client.zig");
const Client = client_mod;
const agent_snapshots = @import("agent_snapshots.zig");
const pane_attachments = @import("pane_attachments.zig");
const pane_closures = @import("pane_closures.zig");
const pane_frames = @import("pane_frames.zig");
const pane_metadata = @import("pane_metadata.zig");
const pane_splits = @import("pane_splits.zig");
const system_metrics = @import("system_metrics.zig");
const tab_closures = @import("tab_closures.zig");
const tab_creations = @import("tab_creations.zig");
const tab_moves = @import("tab_moves.zig");
const tab_renames = @import("tab_renames.zig");
const tab_snapshots = @import("tab_snapshots.zig");
const workspace_creations = @import("workspace_creations.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");
const workspace_lists = @import("workspace_lists.zig");
const workspace_snapshots = @import("workspace_snapshots.zig");
const monotonic = client_mod.monotonic;

const WorkspaceClosureAction = union(enum) {
    stay,
    exit,
    switch_to: schema.WorkspaceId,
};

fn workspaceClosureAction(
    workspace_closed: bool,
    previous_workspace: ?schema.WorkspaceId,
) WorkspaceClosureAction {
    if (!workspace_closed) return .stay;
    return if (previous_workspace) |workspace| .{ .switch_to = workspace } else .exit;
}

fn failureTitle(continuation: client_requests.Continuation) []const u8 {
    return switch (continuation) {
        .split => "Could not split pane",
        .close_pane => "Could not close pane",
        .attach_pane => "Could not attach pane",
        .create_workspace => "Could not create workspace",
        .rename_workspace => "Could not rename workspace",
        .create_tab => "Could not create tab",
        .rename_tab => "Could not rename tab",
        .close_tab => "Could not close tab",
        .move_tab => "Could not move tab",
        .notification => "Could not show notification",
        .initial_open, .workspace_snapshot, .tab_snapshot => "Runtime request failed",
        .ignored => "Request ignored",
    };
}

fn notificationTarget(
    continuation: client_requests.Continuation,
) widgets.notification.Target {
    return switch (continuation) {
        .split => |split| .{ .focus_pane = split.target_pane },
        .close_pane, .attach_pane => |operation| .{ .select_tab = operation.location.tab_id },
        .tab_snapshot, .rename_tab, .close_tab, .move_tab => |location| .{
            .select_tab = location.tab_id,
        },
        .rename_workspace, .workspace_snapshot => |location| workspaceNotificationTarget(location),
        .create_tab => |creation| workspaceNotificationTarget(creation.workspace),
        .initial_open, .create_workspace, .notification, .ignored => .none,
    };
}

fn workspaceNotificationTarget(location: schema.WorkspaceLocation) widgets.notification.Target {
    return switch (location) {
        .workspace => |workspace| .{ .select_workspace = workspace },
        .worktree => .none,
    };
}

/// Routes one decoded message from the runtime.
pub fn handleServerMessage(client: *Client, message: schema.ServerMessage) !?u8 {
    switch (message) {
        .pane_opened => |opened| try handlePaneOpened(client, opened),
        .tab_snapshot => |snapshot| try handleTabSnapshot(client, snapshot),
        .workspace_snapshot => |snapshot| try handleWorkspaceSnapshot(client, snapshot),
        .tab_created => |created| try handleTabCreated(client, created),
        .tab_renamed => |renamed| try handleTabRenamed(client, renamed),
        .tab_closed => |closed| return handleTabClosed(client, closed),
        .tab_moved => |moved| try handleTabMoved(client, moved),
        .pane_frame => |frame| _ = try pane_frames.apply(client, frame),
        .pane_cwd => |cwd| _ = try pane_metadata.applyCwd(client, cwd),
        .pane_foreground => |foreground| _ = try pane_metadata.applyForeground(client, foreground),
        .pane_clipboard => |clipboard| try handlePaneClipboard(client, clipboard),
        .pane_exited => |exited| try handlePaneExited(client, exited),
        .request_failed => |failure| try handleRequestFailed(client, failure),
        .notification => |notification| try handleRuntimeNotification(client, notification),
        .notification_shown => |shown| try handleNotificationShown(client, shown),
        .agent_sound => |sound| try handleAgentSound(client, sound),
        .resync_required => |required| return handleResyncMessage(client, required),
        .runtime_stopping => return 0,
        .history_results => return error.UnexpectedHistoryResults,
        .proxy_status => |status| try handleProxyStatus(client, status),
        .agent_snapshot => |snapshot| _ = try agent_snapshots.apply(client, snapshot),
        .system_metrics => |metrics| _ = try system_metrics.apply(client, metrics),
        .workspace_list => |list| _ = try workspace_lists.apply(client, list),
        .graphics_snapshot,
        .graphics_image,
        .graphics_shared_image,
        .graphics_image_chunk,
        .graphics_placement,
        .graphics_delete_image,
        .graphics_delete_placement,
        => try handleGraphics(client, message),
    }
    return null;
}

fn handleAgentSound(client: *Client, notification: schema.AgentSoundNotification) !void {
    if (!client.model.knowsAgent(.{
        .pane_id = notification.pane_id,
        .pane_generation = notification.pane_generation,
    })) {
        return;
    }

    try client.scheduleAgentSound(notification.sound);
}

/// Entrypoint for a clipboard write a pane requested via OSC 52: the bytes
/// go straight to the host terminal, never through the cell diff.
fn handlePaneClipboard(client: *Client, clipboard: schema.PaneClipboard) !void {
    if (clipboard.pane_id == .invalid) return error.UnexpectedPane;
    try term.writeClipboard(client.writer, clipboard.bytes);
    try client.writer.flush();
}

/// Entrypoint for a notification the runtime pushes on its own behalf.
fn handleRuntimeNotification(client: *Client, notification: schema.Notification) !void {
    try client.notify(.{
        .level = switch (notification.level) {
            .info => .info,
            .success => .success,
            .warning => .warning,
            .failure => .failure,
        },
        .title = notification.title,
        .message = notification.message,
        .target = switch (notification.target) {
            .none => .none,
            .pane => |pane_id| .{ .focus_pane = pane_id },
            .tab => |tab_id| .{ .select_tab = tab_id },
            .workspace => |workspace_id| .{ .select_workspace = workspace_id },
        },
        .duration_ns = @as(u64, notification.duration_ms) * std.time.ns_per_ms,
    });
}

/// Entrypoint for the delivery report of a notification this client asked
/// the runtime to fan out.
fn handleNotificationShown(client: *Client, shown: schema.NotificationShown) !void {
    const continuation = client.requests.take(shown.request_id) orelse
        return error.UnexpectedNotificationReply;
    if (continuation != .notification) return error.UnexpectedNotificationReply;
    if (shown.delivered_clients == 0) try client.notify(.{
        .level = .failure,
        .title = "Notification not delivered",
        .message = "No connected client could accept the notification",
    });
}

/// Entrypoint for a resync demand: reconcile in place, follow the runtime
/// to a surviving workspace, or exit when nothing survives.
fn handleResyncMessage(client: *Client, required: schema.ResyncRequired) !?u8 {
    if (required.workspace_closed)
        client.navigation_history.forget(required.workspace);
    switch (workspaceClosureAction(
        required.workspace_closed,
        required.previous_workspace,
    )) {
        .stay => try handleResyncRequired(client, required),
        .exit => return 0,
        .switch_to => |previous| {
            _ = try workspace_handoffs.requestWorkspace(client, previous);
        },
    }
    return null;
}

/// The proxy interception indicator, announced once per flip.
fn handleProxyStatus(client: *Client, status: schema.ProxyStatus) !void {
    if (client.view.proxy_tls_active == status.active) return;
    client.view.setProxyTlsActive(status.active);
    try client.notify(.{
        .level = if (status.active) .warning else .info,
        .title = if (status.active) "TLS interception active" else "TLS interception stopped",
        .message = if (status.active)
            "Agent network traffic is being observed"
        else
            "Agent network traffic is no longer observed",
        .duration_ns = if (status.active)
            7 * std.time.ns_per_s
        else
            widgets.notification.default_duration_ns,
    });
}

/// An open-pane reply: routed by the continuation that asked for it.
fn handlePaneOpened(client: *Client, opened: schema.PaneOpened) !void {
    const continuation = client.requests.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    switch (continuation) {
        .initial_open => {
            var use_case = workspace_handoffs.confirmationHandler(client);
            try use_case.execute(try workspace_handoffs.arrival(client, opened));
            return;
        },
        .create_workspace => |requested_size| {
            var use_case = workspace_creations.confirmationHandler(client);
            _ = try use_case.execute(workspace_creations.confirmation(client, opened, requested_size));
            return;
        },
        .split => |split| {
            var use_case = pane_splits.confirmationHandler(client);
            _ = try use_case.execute(.{
                .requested = .{
                    .target_pane = split.target_pane,
                    .location = split.location,
                    .axis = split.axis,
                    .area = split.area,
                },
                .confirmed_pane = opened.pane_id,
                .confirmed_location = opened.location,
                .created = opened.created,
            });
            return;
        },
        .attach_pane => |attachment| {
            var use_case = pane_attachments.confirmationHandler(client);
            _ = try use_case.execute(.{
                .requested = .{
                    .pane_id = attachment.pane_id,
                    .location = attachment.location,
                },
                .confirmed = .{
                    .pane_id = opened.pane_id,
                    .location = opened.location,
                },
                .created = opened.created,
            });
            return;
        },
        .ignored => return,
        else => return error.UnexpectedRequest,
    }
}

/// Applies one correlated canonical tab snapshot.
fn handleTabSnapshot(client: *Client, snapshot: schema.TabSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    if (continuation != .tab_snapshot or
        !std.meta.eql(continuation.tab_snapshot, snapshot.location))
    {
        return error.UnexpectedTabSnapshot;
    }

    var use_case = tab_snapshots.reconciliationHandler(client);
    try use_case.execute(snapshot);
}

/// Applies one correlated canonical workspace snapshot.
fn handleWorkspaceSnapshot(client: *Client, snapshot: schema.WorkspaceSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };
    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var use_case = workspace_snapshots.reconciliationHandler(client);
    try use_case.execute(snapshot);
}

/// A created tab becomes active; the previous one detaches.
fn handleTabCreated(client: *Client, created: schema.TabCreated) !void {
    const continuation = client.requests.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    if (continuation != .create_tab or
        !std.meta.eql(continuation.create_tab.workspace, created.location.workspace))
        return error.UnexpectedTabCreated;

    var use_case = tab_creations.confirmationHandler(client);
    _ = try use_case.execute(tab_creations.confirmation(created, continuation.create_tab.size));
}

/// A confirmed tab rename.
fn handleTabRenamed(client: *Client, renamed: schema.TabRenamed) !void {
    const continuation = client.requests.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    if (continuation != .rename_tab or !std.meta.eql(continuation.rename_tab, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    var use_case = tab_renames.confirmationHandler(client);
    _ = use_case.execute(tab_renames.confirmation(renamed)) catch return error.UnexpectedTabRenamed;
}

/// A canonical tab-removal response or lifecycle fact.
fn handleTabClosed(client: *Client, closed: schema.TabClosed) !?u8 {
    const trigger: tab_closures.RemovalTrigger = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = client.requests.take(closed.request_id) orelse
            return error.UnexpectedTabClosed;
        if (continuation == .ignored) {
            return null;
        }
        if (continuation != .close_tab or
            !std.meta.eql(continuation.close_tab, closed.location))
        {
            return error.UnexpectedTabClosed;
        }

        break :requested .requested;
    };

    var use_case = tab_closures.removalHandler(client);
    return switch (try use_case.execute(tab_closures.removal(closed, trigger))) {
        .continue_running => null,
        .exit => 0,
    };
}

/// A confirmed tab reorder.
fn handleTabMoved(client: *Client, moved: schema.TabMoved) !void {
    const continuation = client.requests.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    if (continuation != .move_tab or
        !std.meta.eql(continuation.move_tab, moved.location))
    {
        return error.UnexpectedTabMoved;
    }

    var use_case = tab_moves.confirmationHandler(client);
    _ = use_case.execute(tab_moves.confirmation(moved)) catch return error.UnexpectedTabMoved;
}

/// A pane's child ended: drop the pane and every piece of client state on it.
fn handlePaneExited(client: *Client, exited: schema.PaneExited) !void {
    var use_case = pane_closures.exitHandler(client);
    _ = try use_case.execute(exited.pane_id);
}

/// A failed request: recover disposable state when needed and tell the user.
fn handleRequestFailed(client: *Client, failure: schema.RequestFailed) !void {
    const continuation = client.requests.take(failure.request_id) orelse return error.UnexpectedRequestFailure;
    var notify_failure = true;
    switch (continuation) {
        .ignored, .close_pane, .rename_tab, .rename_workspace, .move_tab => {},
        .split => |split| {
            var recovery = pane_splits.recoveryHandler(client);
            const status = try recovery.execute(.{
                .target_pane = split.target_pane,
                .location = split.location,
                .axis = split.axis,
                .area = split.area,
            });
            notify_failure = status != .stale;
        },
        .attach_pane => |attachment| {
            if (failure.code == .pane_not_found) {
                var recovery = pane_attachments.recoveryHandler(client);
                _ = try recovery.execute(.{
                    .pane_id = attachment.pane_id,
                    .location = attachment.location,
                });
            }
        },
        .close_tab => |location| {
            var recovery = tab_closures.recoveryHandler(client);
            _ = try recovery.execute(location);
        },
        .create_workspace, .notification => {},
        .initial_open => |open| {
            var recovery = workspace_handoffs.recoveryHandler(client);
            if (try recovery.execute(.{
                .fallback_workspace = open.fallback_workspace,
                .code = failure.code,
            }) == .unrecoverable) {
                return error.RuntimeRequestFailed;
            }
            return;
        },
        .create_tab => {},
        .workspace_snapshot, .tab_snapshot => return error.RuntimeRequestFailed,
    }
    if (continuation == .ignored or !notify_failure) {
        return;
    }

    try client.notify(.{
        .level = .failure,
        .title = failureTitle(continuation),
        .message = failure.message,
        .target = notificationTarget(continuation),
        .duration_ns = 7 * std.time.ns_per_s,
    });
}

pub fn handleResyncRequired(client: *Client, required: schema.ResyncRequired) !void {
    const workspace = client.model.workspace.workspace orelse return error.UnexpectedResync;
    if (!std.meta.eql(workspace, required.workspace)) return error.UnexpectedResync;
    if (client.requests.has(.workspace_snapshot)) return;
    try client.requestWorkspaceSnapshot(workspace);
}

/// One graphics message; a revision break asks for a graphics snapshot.
fn handleGraphics(client: *Client, message: schema.ServerMessage) !void {
    if (comptime diagnostics.enabled) switch (message) {
        .graphics_image, .graphics_shared_image => client.metrics.graphics_images += 1,
        else => {},
    };
    switch (message) {
        .graphics_snapshot => |snapshot| client.graphics_store.applySnapshot(snapshot) catch |err| switch (err) {
            error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, snapshot.pane_id),
            else => return err,
        },
        .graphics_image => |image| {
            client.graphics_store.applyImage(image) catch |err| switch (err) {
                error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, image.pane_id),
                else => return err,
            };
            if (client.model.workspace.tabForPane(image.pane_id)) |tab|
                tab.model.setGraphicsPlaceholder(image.pane_id, client.capabilities.kitty_graphics != .supported);
        },
        .graphics_shared_image => |image| {
            client.graphics_store.applySharedImage(image) catch |err| switch (err) {
                error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, image.pane_id),
                // The mapping should never fail on the machine this
                // client declared it shares with the runtime. If it does,
                // renegotiate down to pixel chunks and resynchronize
                // instead of dying over one image.
                error.GraphicsSharedMappingFailed => {
                    try client.enqueue(.{ .configure_graphics = .{ .shared = false } });
                    try requestGraphicsSnapshot(client, image.pane_id);
                },
                else => return err,
            };
            if (client.model.workspace.tabForPane(image.pane_id)) |tab|
                tab.model.setGraphicsPlaceholder(image.pane_id, client.capabilities.kitty_graphics != .supported);
        },
        .graphics_image_chunk => |chunk| client.graphics_store.applyChunk(chunk) catch |err| switch (err) {
            error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, chunk.pane_id),
            else => return err,
        },
        .graphics_placement => |placement| client.graphics_store.applyPlacement(placement) catch |err| switch (err) {
            error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, placement.pane_id),
            else => return err,
        },
        .graphics_delete_image => |deleted| {
            client.graphics_store.deleteImage(deleted) catch |err| switch (err) {
                error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, deleted.pane_id),
                else => return err,
            };
            if (client.model.workspace.tabForPane(deleted.pane_id)) |tab|
                tab.model.setGraphicsPlaceholder(deleted.pane_id, client.capabilities.kitty_graphics != .supported and
                    client.graphics_store.hasPaneGraphics(deleted.pane_id));
        },
        .graphics_delete_placement => |deleted| client.graphics_store.deletePlacement(deleted) catch |err| switch (err) {
            error.GraphicsResyncRequired => try requestGraphicsSnapshot(client, deleted.pane_id),
            else => return err,
        },
        else => unreachable,
    }
    try client.presenter.requestDraw();
}

fn requestGraphicsSnapshot(client: *Client, pane_id: schema.PaneId) !void {
    try client.enqueue(.{ .request_graphics_snapshot = .{
        .pane_id = pane_id,
    } });
}

test "workspace closure exits only when no predecessor survives" {
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction.stay,
        workspaceClosureAction(false, null),
    );
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction.exit,
        workspaceClosureAction(true, null),
    );
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction{ .switch_to = @enumFromInt(7) },
        workspaceClosureAction(true, @enumFromInt(7)),
    );
}
