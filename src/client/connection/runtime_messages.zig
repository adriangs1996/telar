//! Runtime messages: receives one decoded runtime message and hands it to the
//! flow it belongs to.
const data = @import("model");
const core = @import("telar-core");
const pane_graphics = @import("../panes/pane_graphics.zig");
const agent_peek = @import("../agents/agent_peek.zig");
const agent_snapshot = @import("../agents/agent_snapshot.zig");
const agent_sound = @import("../agents/agent_sound.zig");
const proxy_status = @import("../agents/proxy_status.zig");
const change_review = @import("../change_review/change_review.zig");
const cli_control = @import("cli_control.zig");
const request_failure = @import("request_failure.zig");
const resync_required = @import("resync_required.zig");
const copy_mode = @import("../input/copy_mode.zig");
const history_palette = @import("../input/history_palette.zig");
const path_picker = @import("../input/path_picker.zig");
const editor_file_links = @import("../links/editor_file_links.zig");
const notifications = @import("../notifications/notifications.zig");
const limit_reached = @import("../notifications/limit_reached.zig");
const pane_attachment = @import("../panes/pane_attachment.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_frames = @import("../panes/pane_frames.zig");
const client_layout = @import("../workspace/client_layout.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const tab_move = @import("../workspace/tab_move.zig");
const tab_removal = @import("../workspace/tab_removal.zig");
const tab_rename = @import("../workspace/tab_rename.zig");
const tab_snapshot = @import("../workspace/tab_snapshot.zig");
const workspace_list_snapshot = @import("../workspace/workspace_list_snapshot.zig");
const Client = @import("../execution/Client.zig");

/// Applies one decoded reply while its borrowed payload remains valid.
/// Example: `_ = try runtime_messages.handleServerMessage(client, try core.decodeServer(bytes));`
pub fn handleServerMessage(client: *Client, message: core.ServerMessage) !?u8 {
    return receiveServerMessage(client, &message);
}

/// Applies the message the transport owns in place. The union is kilobytes
/// for its largest reply while a pane frame is 168 bytes, so the runtime
/// read never copies it whole.
/// Example: `_ = try runtime_messages.receiveServerMessage(client, &received.message);`
pub fn receiveServerMessage(client: *Client, message: *const core.ServerMessage) !?u8 {
    switch (message.*) {
        .change_review_changed => |notification| {
            _ = change_review.changeReviewChanged(&client.model, notification);
        },
        .change_review_snapshot => |snapshot| {
            _ = try change_review.applyChangeReview(&client.model, snapshot);
        },
        .editor_opened => |reply| {
            try editor_file_links.completeEditorOpen(client, reply);
        },
        .request_completed => |reply| {
            const continuation = client.model.request_lifecycle.tracker.take(reply.request_id) orelse return error.UnexpectedControlReply;
            if (continuation != .ignored and continuation != .peek_action) {
                return error.UnexpectedControlReply;
            }
        },
        .pane_opened => |opened| _ = try pane_attachment.completePaneOpen(client, opened),
        // Worktree registration is a CLI request; a UI never asks for it.
        .worktree_registered => return error.UnexpectedControlReply,
        .tab_snapshot => |snapshot| _ = try tab_snapshot.applyTabSnapshot(client, snapshot),
        .workspace_snapshot => |snapshot| try workspace_list_snapshot.applyWorkspaceSnapshot(client, snapshot),
        .tab_created => |created| _ = try tab_creation.completeTabCreation(client, created),
        .tab_renamed => |renamed| _ = try tab_rename.completeTabRename(&client.model, renamed),
        .tab_closed => |closed| switch (try tab_removal.completeTabClose(client, closed)) {
            .applied, .ignored => {},
            .exit => return 0,
        },
        .tab_moved => |moved| _ = try tab_move.completeTabMove(&client.model, moved),
        .pane_frame => |frame| _ = try pane_frames.receivePaneFrame(client, frame),
        .pane_cwd => |cwd| _ = try data.pane_metadata.update(
            &client.model,
            .{
                .cwd = .{
                    .pane_id = cwd.pane_id,
                    .path = cwd.cwd,
                },
            },
        ),
        .pane_foreground => |foreground| _ = try data.pane_metadata.update(
            &client.model,
            .{
                .foreground = .{
                    .pane_id = foreground.pane_id,
                    .name = foreground.name,
                },
            },
        ),
        .pane_title => |title| _ = try data.pane_metadata.update(
            &client.model,
            .{
                .title = .{
                    .pane_id = title.pane_id,
                    .title = title.title,
                },
            },
        ),
        .pane_progress => |progress| _ = try pane_frames.applyPaneProgress(client, progress),
        .client_command => |command| try cli_control.completeClientCommand(client, command),
        .pane_focus_command => |command| try pane_focus.completePaneFocusCommand(client, command),
        .pane_matches => |found| _ = try copy_mode.applyPaneMatches(client, found),
        .pane_clipboard => |clipboard| {
            if (clipboard.pane_id == .invalid) {
                return error.UnexpectedPane;
            }
            try client.model.to_host.writeClipboard(client.gpa, clipboard.bytes);
        },
        .pane_exited => |exited| _ = try pane_closure.applyPaneExit(client, exited),
        .request_failed => |failure| {
            if (!client.model.history_palette.fail(failure) and !client.model.path_picker.fail(failure)) {
                _ = try request_failure.failRuntimeRequest(client, failure);
            }
        },
        .notification => |notification| _ = try notifications.applyRuntimeNotification(client, notification),
        .notification_shown => |shown| _ = try notifications.completeNotificationDelivery(client, shown),
        .agent_sound => |sound| _ = try agent_sound.applyAgentSound(client, sound),
        .client_layout_snapshot => |snapshot| try client_layout.restoreClientLayout(client, snapshot),
        .resync_required => |required| {
            if (try resync_required.applyResyncRequirement(client, required) == .exit) {
                return 0;
            }
        },
        .runtime_stopping => return 0,
        .history_results => |results| _ = try history_palette.applyHistoryResults(client, results),
        .history_pruned => |confirmation| _ = try history_palette.completeHistoryPrune(&client.model, confirmation),
        .history_output => |output| _ = client.model.history_palette.applyOutput(output),
        .command_suggestion => |suggested| _ = client.model.suggestion.apply(suggested),
        .pane_text => |text| try agent_peek.receiveScreen(&client.model, text),
        .path_results => |results| try path_picker.receive(client, results),
        .client_command_result, .client_list, .history_stats_result, .pane_focus_result, .limit_list => return error.UnexpectedControlReply,
        .proxy_status => |status| _ = try proxy_status.applyProxyStatus(client, status),
        .agent_snapshot => |snapshot| {
            _ = try agent_snapshot.applyAgentSnapshot(client, snapshot);
            try agent_peek.requestScreen(&client.model);
        },
        .system_metrics => |metrics| _ = try data.system_metrics.reconcile(
            &client.model,
            .{
                .runtime_revision = metrics.revision,
                .cpu_percent = metrics.cpu_percent,
                .memory_used_decigib = metrics.memory_used_decigib,
                .battery_percent = if (metrics.has_battery) metrics.battery_percent else null,
                .cpu_count = metrics.cpu_count,
                .memory_total_decigib = metrics.memory_total_decigib,
            },
        ),
        .workspace_list => |list| try workspace_list_snapshot.applyWorkspaceList(client, list),
        .graphics_snapshot => |snapshot| {
            const outcome = try pane_graphics.applyPaneGraphics(
                client,
                .{
                    .snapshot = snapshot,
                },
            );
            // A snapshot that asked for another did not resume the pane.
            if (outcome != .resync_requested) {
                try limit_reached.receiveGraphicsSnapshot(client, snapshot);
            }
        },
        .graphics_image => |image| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .image = image,
            },
        ),
        .graphics_shared_image => |image| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .shared_image = image,
            },
        ),
        .graphics_image_chunk => |chunk| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .image_chunk = chunk,
            },
        ),
        .graphics_placement => |placement| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .placement = placement,
            },
        ),
        .graphics_delete_image => |deleted| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .delete_image = deleted,
            },
        ),
        .graphics_delete_placement => |deleted| _ = try pane_graphics.applyPaneGraphics(
            client,
            .{
                .delete_placement = deleted,
            },
        ),
    }

    return null;
}
