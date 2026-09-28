//! One decoded client message reaches the procedure of its flow. Replies
//! queue on the sender's delivery; the update's flush sends them.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const agent_done = @import("agent_done.zig");
const agent_hooks = @import("agent_hooks.zig");
const change_review = @import("change_review.zig");
const client_control = @import("client_control.zig");
const client_delivery = @import("client_delivery.zig");
const client_layout_persistence = @import("client_layout_persistence.zig");
const command_history = @import("command_history.zig");
const copy_mode = @import("copy_mode.zig");
const link_opening = @import("link_opening.zig");
const path_picker = @import("path_picker.zig");
const notifications = @import("notifications.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_closure = @import("pane_closure.zig");
const pane_frame = @import("pane_frame.zig");
const pane_graphics = @import("pane_graphics.zig");
const pane_input = @import("pane_input.zig");
const pane_resize = @import("pane_resize.zig");
const pane_search = @import("pane_search.zig");
const pane_split = @import("pane_split.zig");
const pane_viewport = @import("pane_viewport.zig");
const suggest_command = @import("suggest_command.zig");
const tab_creation = @import("tab_creation.zig");
const tab_move = @import("tab_move.zig");
const tab_removal = @import("tab_removal.zig");
const tab_rename = @import("tab_rename.zig");
const tab_snapshot_reconciliation = @import("tab_snapshot_reconciliation.zig");
const terminal_colors = @import("terminal_colors.zig");
const workspace_creation = @import("workspace_creation.zig");
const workspace_reconciliation = @import("workspace_reconciliation.zig");
const workspace_rename = @import("workspace_rename.zig");
const worktree_lifecycle = @import("worktree_lifecycle.zig");
const agent_control = @import("agent_control.zig");

/// Calls the procedure that owns `message`. An error drops the sender.
///
/// ```zig
/// try client_request.receive(model, session, message);
/// ```
pub fn receive(model: *RuntimeModel, session: *Session, message: core.ClientMessage) !void {
    return switch (message) {
        .open_editor => |request| link_opening.start(model, session, request),
        .find_paths => |request| path_picker.request(
            model,
            session,
            request,
        ),
        .open_pane => |request| pane_attachment.open(model, session, request),
        .detach_pane => |request| pane_attachment.detach(model, session, request),
        .create_pane => |request| pane_split.split(model, session, request),
        .close_pane => |request| pane_closure.close(model, session, request),
        .pane_input => |request| pane_input.send(model, session, request),
        .send_pane_text => |request| pane_input.sendText(model, session, request),
        .pane_resize => |request| pane_resize.resize(model, session, request),
        .frame_ack => |request| pane_frame.acknowledge(model, session, request),
        .request_snapshot => |request| pane_frame.snapshot(model, session, request),
        .set_pane_viewport => |request| pane_viewport.scroll(model, session, request),
        .copy_selection => |request| copy_mode.copy(model, session, request),
        .search_pane => |request| pane_search.start(model, session, request),
        .read_pane => |request| session.delivery.responses.push(.{ .pane_text = .{
            .request_id = request.request_id,
            .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
            .rows = request.rows,
            .source = request.source,
        } }),
        .request_graphics_snapshot => |request| pane_graphics.snapshot(model, session, request),
        .graphics_credit => |request| pane_graphics.returnCredit(model, session, request),
        .configure_graphics => |request| pane_graphics.configure(model, session, request),
        .configure_terminal_colors => |request| terminal_colors.configure(model, session, request),
        .request_tab_snapshot => |request| tab_snapshot_reconciliation.snapshot(model, session, request),
        .create_tab => |request| tab_creation.create(model, session, request),
        .rename_tab => |request| tab_rename.rename(model, session, request),
        .close_tab => |request| tab_removal.remove(model, session, request),
        .move_tab => |request| tab_move.move(model, session, request),
        .request_workspace_snapshot => |request| workspace_reconciliation.snapshot(model, session, request),
        .create_workspace => |request| workspace_creation.create(model, session, request),
        .rename_workspace => |request| workspace_rename.rename(model, session, request),
        .query_history => |request| command_history.query(model, session, request),
        .import_history => |request| command_history.importBatch(model, session, request),
        .delete_history => |request| command_history.remove(model, session, request),
        .prune_history => |request| command_history.prune(model, session, request),
        .read_history_output => |request| command_history.readOutput(model, session, request),
        .history_stats => |request| command_history.stats(model, session, request),
        .suggest_command => |request| suggest_command.start(model, session, request),
        .query_change_review => |request| change_review.start(model, session, request),
        .change_review_command => |request| change_review.start(model, session, request),
        .report_change_review_sample => |request| change_review.start(model, session, request),
        .query_agents => session.delivery.requestAgentSnapshot(),
        .acknowledge_agent => |request| agent_done.acknowledge(model, request),
        .report_agent_session => |request| agent_hooks.receiveSession(model, session, request),
        .report_agent => |request| agent_hooks.receive(model, session, request),
        .report_agent_command => |request| agent_hooks.receiveCommand(model, session, request),
        .report_agent_title => |request| agent_hooks.receiveTitle(model, session, request),
        .request_runtime_state => |request| session.delivery.requestRuntimeState(request.client_identity),
        .update_client_layout => |request| client_layout_persistence.retain(model, session, request),
        .show_notification => |request| notifications.show(model, session, request),
        .runtime_stop => client_delivery.stop(model, session),
        .request_client_command => |request| client_control.requestCommand(model, session, request),
        .complete_client_command => |request| client_control.finishCommand(model, session, request),
        .detach_client => |request| client_control.detach(model, session, request),
        .query_clients => |request| client_control.list(model, session, request),
        .request_pane_focus => |request| client_control.requestFocus(model, session, request),
        .complete_pane_focus => |request| client_control.finishFocus(model, session, request),
        .register_worktree => |request| worktree_lifecycle.register(model, session, request),
        .launch_worktree => |request| worktree_lifecycle.launch(model, session, request),
        .launch_tab => |request| tab_creation.launch(model, session, request),
        .forget_worktree => |request| worktree_lifecycle.forget(model, session, request),
        .interrupt_agent => |request| agent_control.interrupt(model, session, request),
        .report_agent_progress => |request| agent_hooks.receiveProgress(model, session, request),
    };
}

/// Queues the `request_failed` reply that answers one rejected request.
///
/// ```zig
/// try client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
/// ```
pub fn fail(session: *Session, request_id: core.RequestId, code: core.FailureCode, message: []const u8) !void {
    try session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = code,
        .message = message,
    } });
}

/// Queues the `request_completed` reply that answers one accepted request.
///
/// ```zig
/// try client_request.complete(session, request.request_id);
/// ```
pub fn complete(session: *Session, request_id: core.RequestId) !void {
    try session.delivery.responses.push(.{ .request_completed = .{ .request_id = request_id } });
}
