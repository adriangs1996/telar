//! Reconciliation of every message the runtime sends: the dispatcher and
//! one named entrypoint per message, operating on the client the way the
//! input handler does. Nothing here owns state — the client does; this
//! file owns the protocol conversation.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../presentation/root.zig");
const term = presentation.screen;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const client_mod = @import("client.zig");
const Client = client_mod;
const agent_snapshots = @import("agent_snapshots.zig");
const pane_closures = @import("pane_closures.zig");
const pane_frames = @import("pane_frames.zig");
const pane_graphics = @import("pane_graphics.zig");
const pane_metadata = @import("pane_metadata.zig");
const pane_openings = @import("pane_openings.zig");
const proxy_status = @import("proxy_status.zig");
const request_failures = @import("request_failures.zig");
const resync_requirements = @import("resync_requirements.zig");
const system_metrics = @import("system_metrics.zig");
const tab_closures = @import("tab_closures.zig");
const tab_creations = @import("tab_creations.zig");
const tab_moves = @import("tab_moves.zig");
const tab_renames = @import("tab_renames.zig");
const tab_snapshots = @import("tab_snapshots.zig");
const workspace_lists = @import("workspace_lists.zig");
const workspace_snapshots = @import("workspace_snapshots.zig");
const monotonic = client_mod.monotonic;

/// Routes one decoded message from the runtime.
pub fn handleServerMessage(client: *Client, message: schema.ServerMessage) !?u8 {
    switch (message) {
        .pane_opened => |opened| _ = try pane_openings.apply(client, opened),
        .tab_snapshot => |snapshot| _ = try tab_snapshots.apply(client, snapshot),
        .workspace_snapshot => |snapshot| try workspace_snapshots.apply(client, snapshot),
        .tab_created => |created| try handleTabCreated(client, created),
        .tab_renamed => |renamed| try handleTabRenamed(client, renamed),
        .tab_closed => |closed| return handleTabClosed(client, closed),
        .tab_moved => |moved| try handleTabMoved(client, moved),
        .pane_frame => |frame| _ = try pane_frames.apply(client, frame),
        .pane_cwd => |cwd| _ = try pane_metadata.applyCwd(client, cwd),
        .pane_foreground => |foreground| _ = try pane_metadata.applyForeground(client, foreground),
        .pane_clipboard => |clipboard| try handlePaneClipboard(client, clipboard),
        .pane_exited => |exited| try handlePaneExited(client, exited),
        .request_failed => |failure| _ = try request_failures.apply(client, failure),
        .notification => |notification| try handleRuntimeNotification(client, notification),
        .notification_shown => |shown| try handleNotificationShown(client, shown),
        .agent_sound => |sound| try handleAgentSound(client, sound),
        .resync_required => |required| {
            if (try resync_requirements.apply(client, required) == .exit) {
                return 0;
            }
        },
        .runtime_stopping => return 0,
        .history_results => return error.UnexpectedHistoryResults,
        .proxy_status => |status| _ = try proxy_status.apply(client, status),
        .agent_snapshot => |snapshot| _ = try agent_snapshots.apply(client, snapshot),
        .system_metrics => |metrics| _ = try system_metrics.apply(client, metrics),
        .workspace_list => |list| _ = try workspace_lists.apply(client, list),
        .graphics_snapshot => |snapshot| _ = try pane_graphics.apply(client, .{ .snapshot = snapshot }),
        .graphics_image => |image| _ = try pane_graphics.apply(client, .{ .image = image }),
        .graphics_shared_image => |image| _ = try pane_graphics.apply(client, .{ .shared_image = image }),
        .graphics_image_chunk => |chunk| _ = try pane_graphics.apply(client, .{ .image_chunk = chunk }),
        .graphics_placement => |placement| _ = try pane_graphics.apply(client, .{ .placement = placement }),
        .graphics_delete_image => |deleted| _ = try pane_graphics.apply(client, .{ .delete_image = deleted }),
        .graphics_delete_placement => |deleted| _ = try pane_graphics.apply(client, .{ .delete_placement = deleted }),
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
