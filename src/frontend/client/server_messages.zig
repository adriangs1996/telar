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
const kitty = graphics.kitty;
const copy_mode = input_capability.copy_mode;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const term = presentation.screen;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const client_mod = @import("client.zig");
const Client = client_mod;
const InputHandler = @import("input_handler.zig");
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
        .pane_clipboard => |clipboard| try handlePaneClipboard(client, clipboard),
        .pane_exited => |exited| try handlePaneExited(client, exited),
        .request_failed => |failure| try handleRequestFailed(client, failure),
        .notification => |notification| try handleRuntimeNotification(client, notification),
        .notification_shown => |shown| try handleNotificationShown(client, shown),
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
        if (alert_count == 0) {
            try client.presenter.requestDraw();
        } else for (alerts[0..alert_count]) |agent| {
            var message_buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s} in pane {d} is {s}",
                .{
                    agentProviderName(agent.provider),
                    schema.id.raw(agent.key.pane_id),
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

fn handleSystemMetrics(client: *Client, metrics: schema.SystemMetrics) !void {
    client.view.setSystemMetrics(.{
        .cpu_percent = metrics.cpu_percent,
        .memory_used_decigib = metrics.memory_used_decigib,
        .battery_percent = if (metrics.has_battery) metrics.battery_percent else null,
    });
    try client.presenter.requestDraw();
}

fn handlePaneCwd(client: *Client, message: schema.PaneCwd) !void {
    const pane = client.tabs.findPane(message.pane_id) orelse return;
    if (!try pane.setCwd(message.cwd)) return;
    client.view.invalidate();
    try client.presenter.requestDraw();
}

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

fn handlePaneOpened(client: *Client, opened: schema.PaneOpened) !void {
    const continuation = client.requests.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    switch (continuation) {
        .initial_open => try bootstrapWorkspace(client, opened),
        .create_workspace => {
            if (!opened.created) return error.UnexpectedRequest;
            try client.clearPaneFocus();
            for (&client.tabs.items) |*slot| {
                const tab = if (slot.*) |*value| value else continue;
                for (&tab.model.panes) |*pane_slot| {
                    const pane = if (pane_slot.*) |*value| value else continue;
                    try client.graphics_store.setPaneVisible(pane.id, false);
                }
            }
            client.tabs.deinit();
            try bootstrapWorkspace(client, opened);
            try client.notify(.{
                .level = .success,
                .title = "Workspace created",
                .message = "The new workspace is ready",
            });
        },
        .split => |split| {
            if (!std.meta.eql(split.location, opened.location))
                return error.UnexpectedPane;
            const tab = client.tabs.tabForPane(split.target_pane) orelse
                return error.UnexpectedPane;
            const model = &tab.model;
            if (model.find(split.target_pane) != null) {
                try model.split(split.target_pane, opened.pane_id, opened.location, split.axis, client.view.workbench());
            } else {
                try model.addDiscovered(opened.pane_id, opened.location, client.view.workbench());
                try model.markAttached(opened.pane_id);
            }
            client.view.invalidate();
            try client.resizeAttached(model, client.view.workbench());
            try client.syncPaneFocus(model);
        },
        .attach_pane => |attachment| {
            if (attachment.pane_id != opened.pane_id or
                !std.meta.eql(attachment.location, opened.location))
                return error.UnexpectedPane;
            const pane = client.tabs.findPane(opened.pane_id) orelse
                return error.UnexpectedPane;
            pane.attached = true;
        },
        else => return error.UnexpectedRequest,
    }
    try client.presenter.requestDraw();
}

fn bootstrapWorkspace(client: *Client, opened: schema.PaneOpened) !void {
    if (client.tabs.count != 0) return error.UnexpectedRequest;
    try client.tabs.bootstrap(
        opened.pane_id,
        opened.location,
        rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
    try client.syncPaneFocus(&client.tabs.active().?.model);
    client.view.invalidate();
    try client.scheduleInputRead();
    const workspace_request_id = try client.nextId();
    try client.enqueueRequest(
        workspace_request_id,
        .{ .workspace_snapshot = opened.location.workspace },
        .{ .request_workspace_snapshot = .{
            .request_id = workspace_request_id,
            .workspace = opened.location.workspace,
        } },
    );
    const tab_request_id = try client.nextId();
    try client.enqueueRequest(
        tab_request_id,
        .{ .tab_snapshot = opened.location },
        .{ .request_tab_snapshot = .{
            .request_id = tab_request_id,
            .location = opened.location,
        } },
    );
}

fn handleTabSnapshot(client: *Client, snapshot: schema.TabSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    if (continuation != .tab_snapshot or
        !std.meta.eql(continuation.tab_snapshot, snapshot.location))
        return error.UnexpectedTabSnapshot;
    const tab = try client.tabs.reconcileTab(snapshot, client.view.workbench());
    const model = &tab.model;
    if (client.tabs.active()) |active| try client.syncPaneFocus(&active.model);
    client.view.invalidate();
    try client.resizeAttached(model, client.view.workbench());
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (pane.attached) continue;
        const size = model.contentSize(pane.id, client.view.workbench()) orelse
            return error.PaneTooSmall;
        const request_id = try client.nextId();
        try client.enqueueRequest(
            request_id,
            .{ .attach_pane = .{
                .pane_id = pane.id,
                .location = snapshot.location,
            } },
            .{ .open_pane = .{
                .request_id = request_id,
                .target = .{ .pane = pane.id },
                .size = size,
                .launch = null,
            } },
        );
    }
    try client.presenter.requestDraw();
}

fn handleWorkspaceSnapshot(client: *Client, snapshot: schema.WorkspaceSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };
    const renamed = continuation == .rename_workspace;
    if (!std.meta.eql(expected_workspace, snapshot.workspace))
        return error.UnexpectedWorkspaceSnapshot;
    var canonical_tabs: [tabs_mod.max_tabs]schema.TabId = undefined;
    var canonical_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |descriptor| {
        canonical_tabs[canonical_count] = descriptor.tab_id;
        canonical_count += 1;
    }
    for (client.tabs.items[0..client.tabs.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        if (std.mem.findScalar(
            schema.TabId,
            canonical_tabs[0..canonical_count],
            tab.location.tab_id,
        ) == null) releaseTabGraphics(&client.graphics_store, tab);
    }
    try client.tabs.reconcileWorkspace(snapshot);
    if (!client.requests.has(.tab_snapshot)) {
        if (client.tabs.active()) |active| {
            if (!active.snapshot_loaded) {
                const request_id = try client.nextId();
                try client.enqueueRequest(
                    request_id,
                    .{ .tab_snapshot = active.location },
                    .{ .request_tab_snapshot = .{
                        .request_id = request_id,
                        .location = active.location,
                    } },
                );
            } else {
                // A resync can mean the geometry lease was released.
                // Re-offer this client's sizes; the runtime adopts them
                // when the lease is free and ignores them otherwise.
                try client.resizeAttached(&active.model, client.view.workbench());
            }
        }
    }
    client.view.invalidate();
    if (renamed) {
        try client.notify(.{
            .level = .success,
            .title = "Workspace renamed",
            .message = "The workspace name was updated",
            .target = notificationTarget(continuation),
        });
    } else try client.presenter.requestDraw();
}

fn handleTabCreated(client: *Client, created: schema.TabCreated) !void {
    const continuation = client.requests.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    if (continuation != .create_tab or
        !std.meta.eql(continuation.create_tab, created.location.workspace))
        return error.UnexpectedTabCreated;
    if (client.tabs.active()) |current| {
        var handler: InputHandler = .{ .client = client };
        try handler.detachTab(current);
    }
    _ = try client.tabs.addCreated(
        created,
        rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
    try client.syncPaneFocus(&client.tabs.active().?.model);
    client.view.invalidate();
    try client.notify(.{
        .level = .success,
        .title = "Tab created",
        .message = created.label,
        .target = .{ .select_tab = created.location.tab_id },
    });
}

fn handleTabRenamed(client: *Client, renamed: schema.TabRenamed) !void {
    const continuation = client.requests.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    if (continuation != .rename_tab or
        !std.meta.eql(continuation.rename_tab, renamed.location))
        return error.UnexpectedTabRenamed;
    if (!client.tabs.rename(renamed.location.tab_id, renamed.label))
        return error.UnexpectedTab;
    client.view.invalidate();
    try client.notify(.{
        .level = .success,
        .title = "Tab renamed",
        .message = renamed.label,
        .target = .{ .select_tab = renamed.location.tab_id },
    });
}

fn handleTabClosed(client: *Client, closed: schema.TabClosed) !?u8 {
    const lifecycle_event = closed.request_id == .none;
    if (lifecycle_event) {
        client.requests.ignoreTab(closed.location.tab_id);
    } else {
        const continuation = client.requests.take(closed.request_id) orelse
            return error.UnexpectedTabClosed;
        if (continuation != .close_tab or
            !std.meta.eql(continuation.close_tab, closed.location))
            return error.UnexpectedTabClosed;
    }
    const was_active = client.tabs.activeConst() != null and
        client.tabs.activeConst().?.location.tab_id == closed.location.tab_id;
    if (was_active) client.forgetPaneFocus();
    // The runtime sends no per-pane exit for a closed tab, so its
    // graphics would stay resident forever without this.
    if (client.tabs.find(closed.location.tab_id)) |closing|
        releaseTabGraphics(&client.graphics_store, closing);
    if (!client.tabs.remove(closed.location.tab_id)) {
        if (lifecycle_event) return null;
        return error.UnexpectedTab;
    }
    switch (workspaceClosureAction(closed.workspace_closed, closed.previous_workspace)) {
        .stay => {},
        .exit => return 0,
        .switch_to => |previous| {
            var handler: InputHandler = .{ .client = client };
            try handler.switchWorkspaceResolved(previous);
            try client.presenter.requestDraw();
            return null;
        },
    }
    if (client.tabs.count == 0) return error.WorkspaceHasNoTabs;
    if (was_active) {
        const active = client.tabs.active().?;
        try client.syncPaneFocus(&active.model);
        const request_id = try client.nextId();
        try client.enqueueRequest(
            request_id,
            .{ .tab_snapshot = active.location },
            .{ .request_tab_snapshot = .{
                .request_id = request_id,
                .location = active.location,
            } },
        );
    }
    client.view.invalidate();
    try client.presenter.requestDraw();
    return null;
}

fn handleTabMoved(client: *Client, moved: schema.TabMoved) !void {
    const continuation = client.requests.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    if (continuation != .move_tab or
        !std.meta.eql(continuation.move_tab, moved.location))
        return error.UnexpectedTabMoved;
    _ = client.tabs.move(moved.location.tab_id, moved.position);
    client.view.invalidate();
    try client.presenter.requestDraw();
}

fn handlePaneFrame(client: *Client, frame: schema.frame.FrameView) !void {
    const pane = client.tabs.findPane(frame.pane_id) orelse return error.UnexpectedPane;
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
    const tab = client.tabs.tabForPane(frame.pane_id) orelse
        return error.UnexpectedPane;
    const applied = try tab.model.applyFrame(frame);
    const should_show_graphics = frame.scroll.atBottom(frame.rows) and
        client.tabs.active() != null and
        std.meta.eql(client.tabs.active().?.location, tab.location);
    if (client.graphics_store.paneVisible(frame.pane_id) != should_show_graphics)
        try client.graphics_store.setPaneVisible(frame.pane_id, should_show_graphics);
    if (client.mode == .copy) {
        const state = &client.mode.copy;
        if (state.pane_id == frame.pane_id) {
            copy_mode.onFrame(state, previous_scroll_offset, frame.scroll);
            const updated = tab.model.find(frame.pane_id).?;
            updated.copy_view = state.view();
            tab.model.composition_invalidated = true;
        }
    }
    if (comptime diagnostics.enabled) {
        client.metrics.frames += 1;
        client.metrics.frame_cells += applied.cells;
        client.metrics.frame_spans += applied.spans;
        if (frame.base_frame_id == 0) client.metrics.snapshots += 1;
        client.metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(client.io)));
    }
    if (client.tabs.active()) |active| try client.syncPaneFocus(&active.model);
    try client.presenter.requestDraw();
}

fn handlePaneExited(client: *Client, exited: schema.PaneExited) !void {
    if (client.mode == .copy and client.mode.copy.pane_id == exited.pane_id)
        client.mode = .normal;
    client.graphics_store.clearPane(exited.pane_id);
    const tab = client.tabs.tabForPane(exited.pane_id);
    const tab_id = if (tab) |value| value.location.tab_id else null;
    if (client.reported_focus == exited.pane_id) client.forgetPaneFocus();
    if (tab) |value| _ = value.model.removePane(exited.pane_id);
    client.view.invalidate();
    const requested = client.requests.completePaneClose(exited.pane_id);
    if (client.tabs.active()) |active| {
        try client.syncPaneFocus(&active.model);
        if (active.model.pane_count != 0)
            try client.resizeAttached(&active.model, client.view.workbench());
    }
    if (!requested) {
        try client.notify(.{
            .level = .warning,
            .title = "Pane exited",
            .message = "The process in this pane has stopped",
            .target = if (tab_id) |id| .{ .select_tab = id } else .none,
        });
    } else try client.presenter.requestDraw();
}

fn handleRequestFailed(client: *Client, failure: schema.RequestFailed) !void {
    const continuation = client.requests.take(failure.request_id) orelse {
        std.debug.print("telar runtime: {s}\n", .{failure.message});
        return error.UnexpectedRequestFailure;
    };
    switch (continuation) {
        .ignored, .close_pane, .rename_tab, .rename_workspace, .move_tab => {},
        .split => {
            if (client.tabs.active()) |active|
                try client.resizeAttached(&active.model, client.view.workbench());
        },
        .attach_pane => |attachment| {
            if (client.tabs.tabForPane(attachment.pane_id)) |tab|
                _ = tab.model.removePane(attachment.pane_id);
            client.view.invalidate();
            if (client.tabs.active()) |active|
                try client.resizeAttached(&active.model, client.view.workbench());
        },
        .close_tab => {
            const active = client.tabs.active().?;
            const request_id = try client.nextId();
            try client.enqueueRequest(
                request_id,
                .{ .tab_snapshot = active.location },
                .{ .request_tab_snapshot = .{
                    .request_id = request_id,
                    .location = active.location,
                } },
            );
        },
        .create_workspace, .notification => {},
        .initial_open, .workspace_snapshot, .tab_snapshot, .create_tab => {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.RuntimeRequestFailed;
        },
    }
    if (continuation == .ignored) {
        try client.presenter.requestDraw();
    } else {
        try client.notify(.{
            .level = .failure,
            .title = failureTitle(continuation),
            .message = failure.message,
            .target = notificationTarget(continuation),
            .duration_ns = 7 * std.time.ns_per_s,
        });
    }
}

pub fn handleResyncRequired(client: *Client, required: schema.ResyncRequired) !void {
    const workspace = client.tabs.workspace orelse return error.UnexpectedResync;
    if (!std.meta.eql(workspace, required.workspace)) return error.UnexpectedResync;
    if (client.requests.has(.workspace_snapshot)) return;
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .workspace_snapshot = workspace },
        .{ .request_workspace_snapshot = .{
            .request_id = request_id,
            .workspace = workspace,
        } },
    );
}

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
            if (client.tabs.tabForPane(image.pane_id)) |tab|
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
            if (client.tabs.tabForPane(image.pane_id)) |tab|
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
            if (client.tabs.tabForPane(deleted.pane_id)) |tab|
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

/// Drops every image, placement, and revision the store holds for the panes
/// of a tab that no longer exists.
fn releaseTabGraphics(store: *kitty.Store, tab: *tabs_mod.Tab) void {
    for (&tab.model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        store.clearPane(pane.id);
    }
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

test "closing a tab releases the graphics its panes held" {
    // Red is infeasible in-process: the leak is the *absence* of this call in
    // the `.tab_closed` arm, which needs a live event loop to drive. The
    // helper the arm now calls is proven here instead.
    var tabs = tabs_mod.Model.init(std.testing.allocator);
    defer tabs.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(@enumFromInt(7), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });

    var store = kitty.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyImage(.{ .pane_id = @enumFromInt(7), .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try std.testing.expect(store.hasPaneGraphics(@enumFromInt(7)));

    releaseTabGraphics(&store, tabs.active().?);
    try std.testing.expect(!store.hasPaneGraphics(@enumFromInt(7)));
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
}
