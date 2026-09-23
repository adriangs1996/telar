const core = @import("telar-core");
const RuntimeModel = @import("../RuntimeModel.zig");
const Session = @import("../client/Session.zig");
const RequestContext = @import("RequestContext.zig");
const panes = @import("operations/panes.zig");
const graphics = @import("operations/graphics.zig");
const workspaces = @import("operations/workspaces.zig");
const tabs = @import("operations/tabs.zig");
const history = @import("operations/history.zig");
const agents = @import("operations/agents.zig");
const reviews = @import("operations/reviews.zig");
const clients = @import("operations/clients.zig");
const notifications = @import("operations/notifications.zig");
const editors = @import("operations/editors.zig");

/// Routes each protocol message directly to its runtime operation.
/// Example: `try requests.dispatch(model, session, message);`.
pub fn dispatch(model: *RuntimeModel, session: *Session, message: core.ClientMessage) !void {
    var context: RequestContext = .{ .model = model, .session = session, .workspaces = model.workspaceRepository() };
    return switch (message) {
        .open_editor => |request| editors.routeOpenEditor(&context, request),
        .open_pane => |request| panes.routeOpenPane(&context, request),
        .pane_input => |request| panes.routePaneInput(&context, request),
        .pane_resize => |request| panes.routePaneResize(&context, request),
        .frame_ack => |request| panes.routeFrameAck(&context, request),
        .request_snapshot => |request| panes.routeRequestSnapshot(&context, request),
        .detach_pane => |request| panes.routeDetachPane(&context, request),
        .runtime_stop => notifications.routeRuntimeStop(&context),
        .request_tab_snapshot => |request| tabs.routeRequestTabSnapshot(&context, request),
        .create_pane => |request| panes.routeCreatePane(&context, request),
        .close_pane => |request| panes.routeClosePane(&context, request),
        .query_history => |request| history.routeQueryHistory(&context, request),
        .suggest_command => |request| agents.routeSuggestCommand(&context, request),
        .request_workspace_snapshot => |request| workspaces.routeRequestWorkspaceSnapshot(&context, request),
        .query_change_review => |request| reviews.routeQueryChangeReview(&context, request),
        .change_review_command => |request| reviews.routeChangeReviewCommand(&context, request),
        .report_change_review_sample => |request| reviews.routeReportChangeReviewSample(&context, request),
        .agent_prompt => |request| agents.control(&context, request),
        .agent_interrupt => |request| agents.control(&context, request),
        .agent_resume => |request| agents.control(&context, request),
        .agent_approval => |request| agents.control(&context, request),
        .query_agent_thread => |request| agents.control(&context, request),
        .query_agent_history => |request| agents.routeQueryAgentHistory(&context, request),
        .create_tab => |request| tabs.routeCreateTab(&context, request),
        .rename_tab => |request| tabs.routeRenameTab(&context, request),
        .close_tab => |request| tabs.routeCloseTab(&context, request),
        .move_tab => |request| tabs.routeMoveTab(&context, request),
        .request_graphics_snapshot => |request| graphics.routeRequestGraphicsSnapshot(&context, request),
        .graphics_credit => |request| graphics.routeGraphicsCredit(&context, request),
        .configure_graphics => |request| graphics.routeConfigureGraphics(&context, request),
        .configure_terminal_colors => |request| graphics.routeConfigureTerminalColors(&context, request),
        .request_runtime_state => |request| clients.routeRequestRuntimeState(&context, request),
        .create_workspace => |request| workspaces.routeCreateWorkspace(&context, request),
        .rename_workspace => |request| workspaces.routeRenameWorkspace(&context, request),
        .set_pane_viewport => |request| panes.routeSetPaneViewport(&context, request),
        .copy_selection => |request| panes.routeCopySelection(&context, request),
        .show_notification => |request| notifications.routeShowNotification(&context, request),
        .update_client_layout => |request| clients.routeUpdateClientLayout(&context, request),
        .acknowledge_agent => |request| agents.routeAcknowledgeAgent(&context, request),
        .request_client_command => |request| try clients.routeClientCommand(&context, request),
        .complete_client_command => |request| try clients.completeClientCommand(&context, request),
        .detach_client => |request| try clients.routeDetachClient(&context, request),
        .query_clients => |request| try clients.routeQueryClients(&context, request),
        .query_agents => |request| agents.routeQueryAgents(&context, request),
        .read_pane => |request| panes.routeReadPane(&context, request),
        .send_pane_text => |request| panes.routeSendPaneText(&context, request),
        .report_agent_session => |request| agents.routeReportAgentSession(&context, request),
        .report_agent => |request| agents.routeReportAgent(&context, request),
        .report_agent_command => |request| agents.routeReportAgentCommand(&context, request),
        .report_agent_title => |request| agents.routeReportAgentTitle(&context, request),
        .search_pane => |request| panes.routeSearchPane(&context, request),
        .import_history => |request| history.routeImportHistory(&context, request),
        .delete_history => |request| history.routeDeleteHistory(&context, request),
        .prune_history => |request| history.routePruneHistory(&context, request),
        .read_history_output => |request| history.routeReadHistoryOutput(&context, request),
        .history_stats => |request| history.routeHistoryStats(&context, request),
        .request_pane_focus => |request| clients.routeRequestPaneFocus(&context, request),
        .complete_pane_focus => |request| clients.routeCompletePaneFocus(&context, request),
    };
}
