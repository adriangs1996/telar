//! Reconciliation of every message the runtime sends: the dispatcher and
//! one named entrypoint per message, operating on the client the way the
//! input handler does. Nothing here owns state — the client does; this
//! file owns the protocol conversation.

const std = @import("std");
const core = @import("telar-core");
const graphics = @import("../graphics/root.zig");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const client_requests = @import("requests.zig");
const widgets = @import("../widgets/root.zig");
const copy_mode = input_capability.copy_mode;
const multiplexer = workspace_capability.multiplexer;
const term = presentation.screen;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const client_mod = @import("client.zig");
const Client = client_mod;
const InputHandler = @import("input_handler.zig");
const pane_attachments = @import("pane_attachments.zig");
const pane_closures = @import("pane_closures.zig");
const pane_splits = @import("pane_splits.zig");
const tab_attachments = @import("tab_attachments.zig");
const tab_snapshots = @import("tab_snapshots.zig");
const workspace_snapshots = @import("workspace_snapshots.zig");
const monotonic = client_mod.monotonic;
const rectSize = multiplexer.rectSize;

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
        .create_tab => |location| workspaceNotificationTarget(location),
        .initial_open, .create_workspace, .notification, .ignored => .none,
    };
}

fn workspaceNotificationTarget(location: schema.WorkspaceLocation) widgets.notification.Target {
    return switch (location) {
        .workspace => |workspace| .{ .select_workspace = workspace },
        .worktree => .none,
    };
}

fn agentProviderName(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "Agent",
        .claude => "Claude",
        .codex => "Codex",
    };
}

fn agentStatusName(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}

fn shouldNotifyAgentStatus(previous: ?schema.AgentStatus, current: schema.AgentStatus) bool {
    const before = previous orelse return false;
    if (before == current) return false;
    return current == .blocked or current == .ready or current == .failed;
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
        .pane_frame => |frame| try handlePaneFrame(client, frame),
        .pane_cwd => |cwd| try handlePaneCwd(client, cwd),
        .pane_foreground => |foreground| try handlePaneForeground(client, foreground),
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
        .agent_snapshot => |snapshot| try handleAgentSnapshot(client, snapshot),
        .system_metrics => |metrics| try handleSystemMetrics(client, metrics),
        .workspace_list => |list| try handleWorkspaceList(client, list),
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
    if (client.view.sidebar_snapshot.find(.{
        .pane_id = notification.pane_id,
        .pane_generation = notification.pane_generation,
    }) == null) return;
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
            var handler: InputHandler = .{ .client = client };
            try handler.switchWorkspaceResolved(previous);
            try client.presenter.requestDraw();
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

/// Replaces the sidebar agent replica and raises actionable status alerts.
fn handleAgentSnapshot(client: *Client, snapshot: schema.AgentSnapshotView) !void {
    var agents: [schema.max_agent_snapshot_entries]widgets.sidebar.AgentInput = undefined;
    var alerts: [widgets.notification.max_items]widgets.sidebar.AgentInput = undefined;
    var alert_count: usize = 0;
    var count: usize = 0;
    var iterator = snapshot.entries();
    while (try iterator.next()) |entry| {
        agents[count] = .{
            .key = .{
                .pane_id = entry.pane_id,
                .pane_generation = entry.pane_generation,
            },
            .location = entry.location,
            .pane_index = entry.pane_index,
            .workspace_label = entry.workspace_label,
            .tab_label = entry.tab_label,
            .session_title = entry.session_title,
            .title_source = entry.title_source,
            .title_state = entry.title_state,
            .cwd_label = entry.cwd_label,
            .provider = entry.provider,
            .status = entry.status,
        };
        const previous = client.view.sidebar_snapshot.find(agents[count].key);
        if (shouldNotifyAgentStatus(
            if (previous) |agent| agent.status else null,
            entry.status,
        ) and alert_count < alerts.len) {
            alerts[alert_count] = agents[count];
            alert_count += 1;
        }
        count += 1;
    }
    const replaced = try client.view.replaceSidebarSnapshot(.{
        .revision = snapshot.revision,
        .agents = agents[0..count],
    });
    if (replaced) {
        if (client.model.workspace.active()) |active| try client.syncPaneFocus(&active.model);
        if (alert_count == 0) {
            try client.presenter.requestDraw();
        } else for (alerts[0..alert_count]) |agent| {
            var message_buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s} in pane {d} is {s}",
                .{
                    agentProviderName(agent.provider),
                    agent.pane_index,
                    agentStatusName(agent.status),
                },
            ) catch "Agent status changed";
            try client.notify(.{
                .level = switch (agent.status) {
                    .blocked => .warning,
                    .ready => .success,
                    .failed => .failure,
                    else => unreachable,
                },
                .title = switch (agent.status) {
                    .blocked => "Agent needs input",
                    .ready => "Agent ready",
                    .failed => "Agent failed",
                    else => unreachable,
                },
                .message = message,
                .target = .{ .focus_pane = agent.key.pane_id },
                .duration_ns = if (agent.status == .failed)
                    7 * std.time.ns_per_s
                else
                    widgets.notification.default_duration_ns,
            });
        }
    }
    try client.scheduleSidebarAnimation();
}

/// Host health for the status bar.
fn handleSystemMetrics(client: *Client, metrics: schema.SystemMetrics) !void {
    client.view.setSystemMetrics(.{
        .cpu_percent = metrics.cpu_percent,
        .memory_used_decigib = metrics.memory_used_decigib,
        .battery_percent = if (metrics.has_battery) metrics.battery_percent else null,
    });
    try client.presenter.requestDraw();
}

/// A pane's observed working directory changed.
fn handlePaneCwd(client: *Client, message: schema.PaneCwd) !void {
    const pane = client.model.workspace.findPane(message.pane_id) orelse return;
    if (!try pane.setCwd(message.cwd)) return;
    client.view.invalidate();
    try client.presenter.requestDraw();
}

fn handlePaneForeground(client: *Client, message: schema.PaneForeground) !void {
    const pane = client.model.workspace.findPane(message.pane_id) orelse return;
    if (!pane.setForegroundName(message.name)) return;
    if (client.model.workspace.tabForPane(message.pane_id)) |tab|
        tab.model.composition_invalidated = true;
    client.view.invalidate();
    try client.presenter.requestDraw();
}

/// Replaces the workspace-list replica at the runtime's revision.
fn handleWorkspaceList(client: *Client, list: schema.WorkspaceListView) !void {
    var entries: [schema.max_workspace_list_entries]widgets.workspace_model.EntryInput = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
        };
        count += 1;
    }
    // A snapshot the fixed-capacity replica cannot hold is dropped rather
    // than fatal: the bar keeps showing the previous list, and the next
    // revision gets another chance.
    const replaced = client.view.replaceWorkspaceList(.{
        .revision = list.revision,
        .entries = entries[0..count],
    }) catch return;
    if (replaced) try client.presenter.requestDraw();
}

/// An open-pane reply: routed by the continuation that asked for it.
fn handlePaneOpened(client: *Client, opened: schema.PaneOpened) !void {
    const continuation = client.requests.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    switch (continuation) {
        .initial_open => try bootstrapWorkspace(client, opened),
        .create_workspace => {
            if (!opened.created) return error.UnexpectedRequest;
            client.rememberCurrentNavigation();
            try client.clearPaneFocus();
            var tabs = client.model.workspace.tabIterator();
            while (tabs.next()) |tab| {
                var panes = tab.model.paneIterator();
                while (panes.next()) |pane| {
                    try client.graphics_store.setPaneVisible(pane.id, false);
                }
            }
            client.model.workspace.deinit();
            try bootstrapWorkspace(client, opened);
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
    try client.presenter.requestDraw();
}

/// First pane of a workspace: builds the tab model and asks for both snapshots.
fn bootstrapWorkspace(client: *Client, opened: schema.PaneOpened) !void {
    if (client.model.workspace.count != 0) return error.UnexpectedRequest;
    try client.model.workspace.bootstrap(
        opened.pane_id,
        opened.location,
        rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
    if (client.navigation_history.find(opened.location.workspace)) |bookmark| {
        if (bookmark.tab_layout) |saved| {
            if (std.meta.eql(bookmark.location, opened.location))
                std.debug.assert(client.model.workspace.restoreLayoutOnNextSnapshot(opened.location, saved));
        }
    }
    try client.syncPaneFocus(&client.model.workspace.active().?.model);
    client.view.invalidate();
    try client.scheduleInputRead();
    try client.requestWorkspaceSnapshot(opened.location.workspace);
    try client.requestTabSnapshot(opened.location);
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
        !std.meta.eql(continuation.create_tab, created.location.workspace))
        return error.UnexpectedTabCreated;

    var use_case = tab_attachments.creationHandler(client);
    _ = try use_case.execute(.{
        .created = .{
            .location = created.location,
            .position = created.position,
            .label = created.label,
            .root_pane_id = created.root_pane_id,
        },
        .size = rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    });
}

/// A confirmed tab rename.
fn handleTabRenamed(client: *Client, renamed: schema.TabRenamed) !void {
    const continuation = client.requests.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    if (continuation != .rename_tab or !std.meta.eql(continuation.rename_tab, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    _ = client.model.renameTab(.{
        .location = renamed.location,
        .label = renamed.label,
    }) catch return error.UnexpectedTabRenamed;
}

/// A closed tab: lifecycle event or reply, possibly ending the workspace.
fn handleTabClosed(client: *Client, closed: schema.TabClosed) !?u8 {
    const lifecycle_event = closed.request_id == .none;
    if (!lifecycle_event) {
        const continuation = client.requests.take(closed.request_id) orelse
            return error.UnexpectedTabClosed;
        if (continuation != .close_tab or
            !std.meta.eql(continuation.close_tab, closed.location))
            return error.UnexpectedTabClosed;
    }

    var use_case = tab_attachments.closureHandler(client);
    const removal = try use_case.execute(.{
        .location = closed.location,
        .workspace_closed = closed.workspace_closed,
    });
    if (removal == null) {
        if (lifecycle_event) {
            client.requests.ignoreTab(closed.location.tab_id);
            return null;
        }

        return error.UnexpectedTab;
    }

    const committed = removal.?;
    if (committed.workspace_closed)
        client.navigation_history.forget(closed.location.workspace);
    switch (workspaceClosureAction(committed.workspace_closed, closed.previous_workspace)) {
        .stay => {},
        .exit => return 0,
        .switch_to => |previous| {
            var handler: InputHandler = .{ .client = client };
            try handler.switchWorkspaceResolved(previous);
            try client.presenter.requestDraw();
            return null;
        },
    }
    return null;
}

/// A confirmed tab reorder.
fn handleTabMoved(client: *Client, moved: schema.TabMoved) !void {
    const continuation = client.requests.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    if (continuation != .move_tab or
        !std.meta.eql(continuation.move_tab, moved.location))
        return error.UnexpectedTabMoved;
    _ = client.model.applyTabPosition(moved.location, moved.position) catch
        return error.UnexpectedTabMoved;
}

/// One pane frame: apply the patch or ask for a snapshot on a broken base.
fn handlePaneFrame(client: *Client, frame: schema.frame.FrameView) !void {
    const pane = client.model.workspace.findPane(frame.pane_id) orelse return error.UnexpectedPane;
    if (!pane.attached) return;
    if (frame.base_frame_id != 0 and
        frame.base_frame_id != pane.applied_frame_id)
    {
        try client.enqueue(.{ .request_snapshot = .{
            .pane_id = frame.pane_id,
            .known_frame_id = pane.applied_frame_id,
        } });
        return;
    }
    const apply_started = diagnostics.now(client.io);
    const previous_scroll_offset = pane.scroll.offset;
    const tab = client.model.workspace.tabForPane(frame.pane_id) orelse
        return error.UnexpectedPane;
    const applied = try tab.model.applyFrame(frame);
    const should_show_graphics = frame.scroll.atBottom(frame.rows) and
        client.model.workspace.active() != null and
        std.meta.eql(client.model.workspace.active().?.location, tab.location);
    if (client.graphics_store.paneVisible(frame.pane_id) != should_show_graphics)
        try client.graphics_store.setPaneVisible(frame.pane_id, should_show_graphics);
    if (client.mode == .copy) {
        const state = &client.mode.copy;
        if (state.pane_id == frame.pane_id) {
            copy_mode.onFrame(state, previous_scroll_offset, frame.scroll);
            tab.model.setPaneCopyView(frame.pane_id, state.view());
        }
    }
    if (comptime diagnostics.enabled) {
        client.metrics.frames += 1;
        client.metrics.frame_cells += applied.cells;
        client.metrics.frame_spans += applied.spans;
        if (frame.base_frame_id == 0) client.metrics.snapshots += 1;
        client.metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(client.io)));
    }
    if (client.model.workspace.active()) |active| try client.syncPaneFocus(&active.model);
    try client.presenter.requestDraw();
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
            var recovery = tab_attachments.closeRecoveryHandler(client);
            _ = try recovery.execute(location);
        },
        .create_workspace, .notification => {},
        .initial_open => |open| {
            const workspace = open.fallback_workspace orelse return error.RuntimeRequestFailed;

            if (failure.code != .pane_not_found) {
                return error.RuntimeRequestFailed;
            }

            client.navigation_history.forget(.{ .workspace = workspace });
            const request_id = try client.nextId();
            try client.enqueueRequest(
                request_id,
                .{ .initial_open = .{} },
                .{ .open_pane = .{
                    .request_id = request_id,
                    .target = .{ .workspace = workspace },
                    .size = rectSize(client.view.workbench()) orelse
                        return error.TerminalTooSmall,
                    .launch = null,
                } },
            );
            client.view.invalidate();
            try client.presenter.requestDraw();
            return;
        },
        .workspace_snapshot, .tab_snapshot, .create_tab => return error.RuntimeRequestFailed,
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

test "agent notifications report only actionable status transitions" {
    try std.testing.expect(!shouldNotifyAgentStatus(null, .blocked));
    try std.testing.expect(!shouldNotifyAgentStatus(.working, .working));
    try std.testing.expect(!shouldNotifyAgentStatus(.ready, .working));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .blocked));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .ready));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .failed));
}
