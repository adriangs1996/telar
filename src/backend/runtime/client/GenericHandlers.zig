const OpenPaneViewType = @import("telar-core").OpenPaneView;
const PaneInputType = @import("telar-core").PaneInput;
const PaneResizeType = @import("telar-core").PaneResize;
const FrameAckType = @import("telar-core").FrameAck;
const RequestSnapshotType = @import("telar-core").RequestSnapshot;
const DetachPaneType = @import("telar-core").DetachPane;
const RequestTabSnapshotType = @import("telar-core").RequestTabSnapshot;
const CreatePaneViewType = @import("telar-core").CreatePaneView;
const ClosePaneType = @import("telar-core").ClosePane;
const QueryHistoryType = @import("telar-core").QueryHistory;
const SuggestCommandType = @import("telar-core").SuggestCommand;
const RequestWorkspaceSnapshotType = @import("telar-core").RequestWorkspaceSnapshot;
const CreateTabViewType = @import("telar-core").CreateTabView;
const RenameTabType = @import("telar-core").RenameTab;
const CloseTabType = @import("telar-core").CloseTab;
const MoveTabType = @import("telar-core").MoveTab;
const RequestGraphicsSnapshotType = @import("telar-core").RequestGraphicsSnapshot;
const GraphicsCreditType = @import("telar-core").GraphicsCredit;
const ConfigureGraphicsType = @import("telar-core").ConfigureGraphics;
const TerminalColors = @import("telar-core").TerminalColors;
const RequestRuntimeStateType = @import("telar-core").RequestRuntimeState;
const CreateWorkspaceViewType = @import("telar-core").CreateWorkspaceView;
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const CopySelectionType = @import("telar-core").CopySelection;
const ShowNotificationType = @import("telar-core").ShowNotification;
const ClientLayoutUpdateViewType = @import("telar-core").ClientLayoutUpdateView;
const AcknowledgeAgentType = @import("telar-core").AcknowledgeAgent;
const QueryAgentsType = @import("telar-core").QueryAgents;
const ReadPaneType = @import("telar-core").ReadPane;
const SendPaneTextType = @import("telar-core").SendPaneText;
const ReportAgentSessionType = @import("telar-core").ReportAgentSession;
const ReportAgentType = @import("telar-core").ReportAgent;
const ReportAgentCommandType = @import("telar-core").ReportAgentCommand;
const ReportAgentTitleType = @import("telar-core").ReportAgentTitle;
const SearchPaneType = @import("telar-core").SearchPane;
const ImportHistoryViewType = @import("telar-core").ImportHistoryView;
const DeleteHistoryType = @import("telar-core").DeleteHistory;
const PruneHistoryType = @import("telar-core").PruneHistory;
const ReadHistoryOutputType = @import("telar-core").ReadHistoryOutput;
const HistoryStatsQueryType = @import("telar-core").HistoryStatsQuery;
const RequestPaneFocusType = @import("telar-core").RequestPaneFocus;
const CompletePaneFocusType = @import("telar-core").CompletePaneFocus;

/// Defines the complete set of request handlers for one context type.
///
/// ```zig
/// const handlers: Handlers(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        open_pane: *const fn (*Context, OpenPaneViewType) anyerror!void,
        pane_input: *const fn (*Context, PaneInputType) anyerror!void,
        pane_resize: *const fn (*Context, PaneResizeType) anyerror!void,
        frame_ack: *const fn (*Context, FrameAckType) anyerror!void,
        request_snapshot: *const fn (*Context, RequestSnapshotType) anyerror!void,
        detach_pane: *const fn (*Context, DetachPaneType) anyerror!void,
        runtime_stop: *const fn (*Context) anyerror!void,
        request_tab_snapshot: *const fn (*Context, RequestTabSnapshotType) anyerror!void,
        create_pane: *const fn (*Context, CreatePaneViewType) anyerror!void,
        close_pane: *const fn (*Context, ClosePaneType) anyerror!void,
        query_history: *const fn (*Context, QueryHistoryType) anyerror!void,
        suggest_command: *const fn (*Context, SuggestCommandType) anyerror!void,
        request_workspace_snapshot: *const fn (*Context, RequestWorkspaceSnapshotType) anyerror!void,
        create_tab: *const fn (*Context, CreateTabViewType) anyerror!void,
        rename_tab: *const fn (*Context, RenameTabType) anyerror!void,
        close_tab: *const fn (*Context, CloseTabType) anyerror!void,
        move_tab: *const fn (*Context, MoveTabType) anyerror!void,
        request_graphics_snapshot: *const fn (*Context, RequestGraphicsSnapshotType) anyerror!void,
        graphics_credit: *const fn (*Context, GraphicsCreditType) anyerror!void,
        configure_graphics: *const fn (*Context, ConfigureGraphicsType) anyerror!void,
        configure_terminal_colors: *const fn (*Context, TerminalColors) anyerror!void,
        request_runtime_state: *const fn (*Context, RequestRuntimeStateType) anyerror!void,
        create_workspace: *const fn (*Context, CreateWorkspaceViewType) anyerror!void,
        rename_workspace: *const fn (*Context, RenameWorkspaceType) anyerror!void,
        set_pane_viewport: *const fn (*Context, SetPaneViewportType) anyerror!void,
        copy_selection: *const fn (*Context, CopySelectionType) anyerror!void,
        show_notification: *const fn (*Context, ShowNotificationType) anyerror!void,
        update_client_layout: *const fn (*Context, ClientLayoutUpdateViewType) anyerror!void,
        acknowledge_agent: *const fn (*Context, AcknowledgeAgentType) anyerror!void,
        query_agents: *const fn (*Context, QueryAgentsType) anyerror!void,
        read_pane: *const fn (*Context, ReadPaneType) anyerror!void,
        send_pane_text: *const fn (*Context, SendPaneTextType) anyerror!void,
        report_agent_session: *const fn (*Context, ReportAgentSessionType) anyerror!void,
        report_agent: *const fn (*Context, ReportAgentType) anyerror!void,
        report_agent_command: *const fn (*Context, ReportAgentCommandType) anyerror!void,
        report_agent_title: *const fn (*Context, ReportAgentTitleType) anyerror!void,
        search_pane: *const fn (*Context, SearchPaneType) anyerror!void,
        import_history: *const fn (*Context, ImportHistoryViewType) anyerror!void,
        delete_history: *const fn (*Context, DeleteHistoryType) anyerror!void,
        prune_history: *const fn (*Context, PruneHistoryType) anyerror!void,
        read_history_output: *const fn (*Context, ReadHistoryOutputType) anyerror!void,
        history_stats: *const fn (*Context, HistoryStatsQueryType) anyerror!void,
        request_pane_focus: *const fn (*Context, RequestPaneFocusType) anyerror!void,
        complete_pane_focus: *const fn (*Context, CompletePaneFocusType) anyerror!void,
    };
}
