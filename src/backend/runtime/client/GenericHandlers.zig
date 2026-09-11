const source_namespace = @import("request_router.zig");
/// Defines the complete set of request handlers for one context type.
///
/// ```zig
/// const handlers: Handlers(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        open_pane: *const fn (*Context, source_namespace.schema.OpenPaneView) anyerror!void,
        pane_input: *const fn (*Context, source_namespace.schema.PaneInput) anyerror!void,
        pane_resize: *const fn (*Context, source_namespace.schema.PaneResize) anyerror!void,
        frame_ack: *const fn (*Context, source_namespace.schema.FrameAck) anyerror!void,
        request_snapshot: *const fn (*Context, source_namespace.schema.RequestSnapshot) anyerror!void,
        detach_pane: *const fn (*Context, source_namespace.schema.DetachPane) anyerror!void,
        runtime_stop: *const fn (*Context) anyerror!void,
        request_tab_snapshot: *const fn (*Context, source_namespace.schema.RequestTabSnapshot) anyerror!void,
        create_pane: *const fn (*Context, source_namespace.schema.CreatePaneView) anyerror!void,
        close_pane: *const fn (*Context, source_namespace.schema.ClosePane) anyerror!void,
        query_history: *const fn (*Context, source_namespace.schema.QueryHistory) anyerror!void,
        suggest_command: *const fn (*Context, source_namespace.schema.SuggestCommand) anyerror!void,
        request_workspace_snapshot: *const fn (*Context, source_namespace.schema.RequestWorkspaceSnapshot) anyerror!void,
        create_tab: *const fn (*Context, source_namespace.schema.CreateTabView) anyerror!void,
        rename_tab: *const fn (*Context, source_namespace.schema.RenameTab) anyerror!void,
        close_tab: *const fn (*Context, source_namespace.schema.CloseTab) anyerror!void,
        move_tab: *const fn (*Context, source_namespace.schema.MoveTab) anyerror!void,
        request_graphics_snapshot: *const fn (*Context, source_namespace.schema.RequestGraphicsSnapshot) anyerror!void,
        graphics_credit: *const fn (*Context, source_namespace.schema.GraphicsCredit) anyerror!void,
        configure_graphics: *const fn (*Context, source_namespace.schema.ConfigureGraphics) anyerror!void,
        configure_terminal_colors: *const fn (*Context, source_namespace.schema.ConfigureTerminalColors) anyerror!void,
        request_runtime_state: *const fn (*Context, source_namespace.schema.RequestRuntimeState) anyerror!void,
        create_workspace: *const fn (*Context, source_namespace.schema.CreateWorkspaceView) anyerror!void,
        rename_workspace: *const fn (*Context, source_namespace.schema.RenameWorkspace) anyerror!void,
        set_pane_viewport: *const fn (*Context, source_namespace.schema.SetPaneViewport) anyerror!void,
        copy_selection: *const fn (*Context, source_namespace.schema.CopySelection) anyerror!void,
        show_notification: *const fn (*Context, source_namespace.schema.ShowNotification) anyerror!void,
        update_client_layout: *const fn (*Context, source_namespace.schema.ClientLayoutUpdateView) anyerror!void,
        acknowledge_agent: *const fn (*Context, source_namespace.schema.AcknowledgeAgent) anyerror!void,
        query_agents: *const fn (*Context, source_namespace.schema.QueryAgents) anyerror!void,
        read_pane: *const fn (*Context, source_namespace.schema.ReadPane) anyerror!void,
        send_pane_text: *const fn (*Context, source_namespace.schema.SendPaneText) anyerror!void,
        report_agent_session: *const fn (*Context, source_namespace.schema.ReportAgentSession) anyerror!void,
        report_agent: *const fn (*Context, source_namespace.schema.ReportAgent) anyerror!void,
        report_agent_command: *const fn (*Context, source_namespace.schema.ReportAgentCommand) anyerror!void,
        report_agent_title: *const fn (*Context, source_namespace.schema.ReportAgentTitle) anyerror!void,
        search_pane: *const fn (*Context, source_namespace.schema.SearchPane) anyerror!void,
        import_history: *const fn (*Context, source_namespace.schema.ImportHistoryView) anyerror!void,
        delete_history: *const fn (*Context, source_namespace.schema.DeleteHistory) anyerror!void,
        prune_history: *const fn (*Context, source_namespace.schema.PruneHistory) anyerror!void,
        read_history_output: *const fn (*Context, source_namespace.schema.ReadHistoryOutput) anyerror!void,
        history_stats: *const fn (*Context, source_namespace.schema.HistoryStatsQuery) anyerror!void,
        request_pane_focus: *const fn (*Context, source_namespace.schema.RequestPaneFocus) anyerror!void,
        complete_pane_focus: *const fn (*Context, source_namespace.schema.CompletePaneFocus) anyerror!void,
    };
}
