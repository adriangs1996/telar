//! Application messages grouped by the part of the product they serve, and
//! the two dispatchers that turn a tagged payload into one of them.
//!
//! Every domain file owns its message types, their tagged encoders and the
//! body decoders; `decodeClient` and `decodeServer` here own the tag switch
//! and the trailing-bytes check, so a payload is never accepted with data
//! after its message.

const OpenPaneViewType = @import("OpenPaneView.zig");
const PaneInputType = @import("PaneInput.zig");
const PaneResizeType = @import("PaneResize.zig");
const FrameAckType = @import("FrameAck.zig");
const RequestSnapshotType = @import("RequestSnapshot.zig");
const DetachPaneType = @import("DetachPane.zig");
const RequestTabSnapshotType = @import("RequestTabSnapshot.zig");
const CreatePaneViewType = @import("CreatePaneView.zig");
const ClosePaneType = @import("ClosePane.zig");
const QueryHistoryType = @import("QueryHistory.zig");
const RequestWorkspaceSnapshotType = @import("RequestWorkspaceSnapshot.zig");
const CreateTabViewType = @import("CreateTabView.zig");
const RenameTabType = @import("RenameTab.zig");
const CloseTabType = @import("CloseTab.zig");
const MoveTabType = @import("MoveTab.zig");
const RequestGraphicsSnapshotType = @import("RequestGraphicsSnapshot.zig");
const GraphicsCreditType = @import("GraphicsCredit.zig");
const ConfigureGraphicsType = @import("ConfigureGraphics.zig");
const TerminalColors = @import("../TerminalColors.zig");
const RequestRuntimeStateType = @import("RequestRuntimeState.zig");
const CreateWorkspaceViewType = @import("CreateWorkspaceView.zig");
const RenameWorkspaceType = @import("RenameWorkspace.zig");
const SetPaneViewportType = @import("SetPaneViewport.zig");
const CopySelectionType = @import("CopySelection.zig");
const ShowNotificationType = @import("ShowNotification.zig");
const AcknowledgeAgentType = @import("AcknowledgeAgent.zig");
const QueryAgentsType = @import("QueryAgents.zig");
const ReadPaneType = @import("ReadPane.zig");
const SendPaneTextType = @import("SendPaneText.zig");
const ReportAgentSessionType = @import("ReportAgentSession.zig");
const ReportAgentType = @import("ReportAgent.zig");
const ReportAgentCommandType = @import("ReportAgentCommand.zig");
const ReportAgentTitleType = @import("ReportAgentTitle.zig");
const SearchPaneType = @import("SearchPane.zig");
const ImportHistoryViewType = @import("ImportHistoryView.zig");
const DeleteHistoryType = @import("DeleteHistory.zig");
const SuggestCommandType = @import("SuggestCommand.zig");
const PruneHistoryType = @import("PruneHistory.zig");
const ReadHistoryOutputType = @import("ReadHistoryOutput.zig");
const HistoryStatsQueryType = @import("HistoryStatsQuery.zig");
const ClientLayoutUpdateViewType = @import("ClientLayoutUpdateView.zig");
const RequestPaneFocusType = @import("RequestPaneFocus.zig");
const CompletePaneFocusType = @import("CompletePaneFocus.zig");
const PaneOpenedType = @import("PaneOpened.zig");
const FrameViewType = @import("../FrameView.zig");
const PaneExitedType = @import("PaneExited.zig");
const RequestFailedType = @import("RequestFailed.zig");
const TabSnapshotViewType = @import("TabSnapshotView.zig");
const HistoryResultsViewType = @import("HistoryResultsView.zig");
const WorkspaceSnapshotViewType = @import("WorkspaceSnapshotView.zig");
const TabCreatedType = @import("TabCreated.zig");
const TabRenamedType = @import("TabRenamed.zig");
const TabClosedType = @import("TabClosed.zig");
const TabMovedType = @import("TabMoved.zig");
const SnapshotType = @import("../Snapshot.zig");
const ImageType = @import("../Image.zig");
const ImageChunkType = @import("../ImageChunk.zig");
const PlacementType = @import("../Placement.zig");
const DeleteImageType = @import("../DeleteImage.zig");
const DeletePlacementType = @import("../DeletePlacement.zig");
const ResyncRequiredType = @import("ResyncRequired.zig");
const SharedImageType = @import("../SharedImage.zig");
const ProxyStatusType = @import("ProxyStatus.zig");
const AgentSnapshotViewType = @import("AgentSnapshotView.zig");
const SystemMetricsType = @import("SystemMetrics.zig");
const WorkspaceListViewType = @import("WorkspaceListView.zig");
const PaneCwdType = @import("PaneCwd.zig");
const PaneForegroundType = @import("PaneForeground.zig");
const PaneClipboardType = @import("PaneClipboard.zig");
const NotificationType = @import("Notification.zig");
const NotificationShownType = @import("NotificationShown.zig");
const AgentSoundNotificationType = @import("../AgentSoundNotification.zig");
const ClientLayoutSnapshotViewType = @import("ClientLayoutSnapshotView.zig");
const PaneTextType = @import("PaneText.zig");
const RequestCompletedType = @import("RequestCompleted.zig");
const PaneTitleType = @import("PaneTitle.zig");
const PaneMatchesViewType = @import("PaneMatchesView.zig");
const HistoryPrunedType = @import("HistoryPruned.zig");
const CommandSuggestionType = @import("CommandSuggestion.zig");
const HistoryOutputType = @import("HistoryOutput.zig");
const HistoryStatsViewType = @import("HistoryStatsView.zig");
const PaneFocusCommandType = @import("PaneFocusCommand.zig");
const PaneFocusResultType = @import("PaneFocusResult.zig");
const PaneProgressType = @import("PaneProgress.zig");
const DecoderType = @import("../Decoder.zig");
const tags = @import("tags.zig");
const pane = @import("pane.zig");
const GenericDerived = @import("../GenericDerived.zig").Type;
const history = @import("history.zig");
const tab = @import("tab.zig");
const runtime = @import("runtime.zig");
const workspace = @import("workspace.zig");
const notification = @import("notification_support.zig");
const layout = @import("layout.zig");
const agent = @import("agent.zig");
const suggestion = @import("suggestion.zig");
const focus = @import("focus.zig");
const frame = @import("../frame_support.zig");
const graphics_bodies = @import("../graphics.zig");
const std = @import("std");

pub const ClientMessage = union(enum) {
    open_pane: OpenPaneViewType,
    pane_input: PaneInputType,
    pane_resize: PaneResizeType,
    frame_ack: FrameAckType,
    request_snapshot: RequestSnapshotType,
    detach_pane: DetachPaneType,
    runtime_stop: void,
    request_tab_snapshot: RequestTabSnapshotType,
    create_pane: CreatePaneViewType,
    close_pane: ClosePaneType,
    query_history: QueryHistoryType,
    request_workspace_snapshot: RequestWorkspaceSnapshotType,
    create_tab: CreateTabViewType,
    rename_tab: RenameTabType,
    close_tab: CloseTabType,
    move_tab: MoveTabType,
    request_graphics_snapshot: RequestGraphicsSnapshotType,
    graphics_credit: GraphicsCreditType,
    configure_graphics: ConfigureGraphicsType,
    configure_terminal_colors: TerminalColors,
    request_runtime_state: RequestRuntimeStateType,
    create_workspace: CreateWorkspaceViewType,
    rename_workspace: RenameWorkspaceType,
    set_pane_viewport: SetPaneViewportType,
    copy_selection: CopySelectionType,
    show_notification: ShowNotificationType,
    acknowledge_agent: AcknowledgeAgentType,
    query_agents: QueryAgentsType,
    read_pane: ReadPaneType,
    send_pane_text: SendPaneTextType,
    report_agent_session: ReportAgentSessionType,
    report_agent: ReportAgentType,
    report_agent_command: ReportAgentCommandType,
    report_agent_title: ReportAgentTitleType,
    search_pane: SearchPaneType,
    import_history: ImportHistoryViewType,
    delete_history: DeleteHistoryType,
    suggest_command: SuggestCommandType,
    prune_history: PruneHistoryType,
    read_history_output: ReadHistoryOutputType,
    history_stats: HistoryStatsQueryType,
    update_client_layout: ClientLayoutUpdateViewType,
    request_pane_focus: RequestPaneFocusType,
    complete_pane_focus: CompletePaneFocusType,
};

pub const ServerMessage = union(enum) {
    pane_opened: PaneOpenedType,
    pane_frame: FrameViewType,
    pane_exited: PaneExitedType,
    request_failed: RequestFailedType,
    runtime_stopping: void,
    tab_snapshot: TabSnapshotViewType,
    history_results: HistoryResultsViewType,
    workspace_snapshot: WorkspaceSnapshotViewType,
    tab_created: TabCreatedType,
    tab_renamed: TabRenamedType,
    tab_closed: TabClosedType,
    tab_moved: TabMovedType,
    graphics_snapshot: SnapshotType,
    graphics_image: ImageType,
    graphics_image_chunk: ImageChunkType,
    graphics_placement: PlacementType,
    graphics_delete_image: DeleteImageType,
    graphics_delete_placement: DeletePlacementType,
    resync_required: ResyncRequiredType,
    graphics_shared_image: SharedImageType,
    proxy_status: ProxyStatusType,
    agent_snapshot: AgentSnapshotViewType,
    system_metrics: SystemMetricsType,
    workspace_list: WorkspaceListViewType,
    pane_cwd: PaneCwdType,
    pane_foreground: PaneForegroundType,
    pane_clipboard: PaneClipboardType,
    notification: NotificationType,
    notification_shown: NotificationShownType,
    agent_sound: AgentSoundNotificationType,
    client_layout_snapshot: ClientLayoutSnapshotViewType,
    pane_text: PaneTextType,
    request_completed: RequestCompletedType,
    pane_title: PaneTitleType,
    pane_matches: PaneMatchesViewType,
    history_pruned: HistoryPrunedType,
    command_suggestion: CommandSuggestionType,
    history_output: HistoryOutputType,
    history_stats_result: HistoryStatsViewType,
    pane_focus_command: PaneFocusCommandType,
    pane_focus_result: PaneFocusResultType,
    pane_progress: PaneProgressType,
};

pub fn decodeClient(payload: []const u8) !ClientMessage {
    var decoder = DecoderType.init(payload);
    const tag = try decodeTag(tags.ClientTag, try decoder.readByte());
    const message: ClientMessage = switch (tag) {
        .open_pane => .{ .open_pane = try pane.decodeOpenPane(&decoder) },
        .pane_input => .{ .pane_input = try pane.decodePaneInput(&decoder) },
        .pane_resize => .{ .pane_resize = try GenericDerived(PaneResizeType).decode(&decoder) },
        .frame_ack => .{ .frame_ack = try GenericDerived(FrameAckType).decode(&decoder) },
        .request_snapshot => .{ .request_snapshot = try GenericDerived(RequestSnapshotType).decode(&decoder) },
        .detach_pane => .{ .detach_pane = try GenericDerived(DetachPaneType).decode(&decoder) },
        .runtime_stop => .{ .runtime_stop = {} },
        .request_tab_snapshot => .{
            .request_tab_snapshot = try GenericDerived(RequestTabSnapshotType).decode(&decoder),
        },
        .create_pane => .{ .create_pane = try pane.decodeCreatePane(&decoder) },
        .close_pane => .{ .close_pane = try GenericDerived(ClosePaneType).decode(&decoder) },
        .query_history => .{ .query_history = try history.decodeQueryHistory(&decoder) },
        .request_workspace_snapshot => .{
            .request_workspace_snapshot = try GenericDerived(RequestWorkspaceSnapshotType).decode(&decoder),
        },
        .create_tab => .{ .create_tab = try tab.decodeCreateTab(&decoder) },
        .rename_tab => .{ .rename_tab = try tab.decodeRenameTab(&decoder) },
        .close_tab => .{ .close_tab = try GenericDerived(CloseTabType).decode(&decoder) },
        .move_tab => .{ .move_tab = try GenericDerived(MoveTabType).decode(&decoder) },
        .request_graphics_snapshot => .{
            .request_graphics_snapshot = try GenericDerived(RequestGraphicsSnapshotType).decode(&decoder),
        },
        .graphics_credit => .{
            .graphics_credit = try GenericDerived(GraphicsCreditType).decode(&decoder),
        },
        .configure_graphics => .{
            .configure_graphics = try GenericDerived(ConfigureGraphicsType).decode(&decoder),
        },
        .configure_terminal_colors => .{ .configure_terminal_colors = try runtime.decodeConfigureTerminalColors(&decoder) },
        .request_runtime_state => .{ .request_runtime_state = try runtime.decodeRequestRuntimeState(&decoder) },
        .create_workspace => .{ .create_workspace = try workspace.decodeCreateWorkspace(&decoder) },
        .rename_workspace => .{ .rename_workspace = try workspace.decodeRenameWorkspace(&decoder) },
        .set_pane_viewport => .{
            .set_pane_viewport = try GenericDerived(SetPaneViewportType).decode(&decoder),
        },
        .copy_selection => .{
            .copy_selection = try GenericDerived(CopySelectionType).decode(&decoder),
        },
        .show_notification => .{ .show_notification = try notification.decodeShowNotification(&decoder) },
        .update_client_layout => .{ .update_client_layout = try layout.decodeClientLayoutUpdate(&decoder) },
        .acknowledge_agent => .{
            .acknowledge_agent = try GenericDerived(AcknowledgeAgentType).decode(&decoder),
        },
        .query_agents => .{ .query_agents = try GenericDerived(QueryAgentsType).decode(&decoder) },
        .read_pane => .{ .read_pane = try GenericDerived(ReadPaneType).decode(&decoder) },
        .send_pane_text => .{ .send_pane_text = try pane.decodeSendPaneText(&decoder) },
        .report_agent_session => .{ .report_agent_session = try agent.decodeReportAgentSession(&decoder) },
        .report_agent => .{ .report_agent = try agent.decodeReportAgent(&decoder) },
        .report_agent_command => .{ .report_agent_command = try agent.decodeReportAgentCommand(&decoder) },
        .report_agent_title => .{ .report_agent_title = try agent.decodeReportAgentTitle(&decoder) },
        .search_pane => .{ .search_pane = try pane.decodeSearchPane(&decoder) },
        .import_history => .{ .import_history = try history.decodeImportHistory(&decoder) },
        .delete_history => .{ .delete_history = try GenericDerived(DeleteHistoryType).decode(&decoder) },
        .suggest_command => .{ .suggest_command = try suggestion.decodeSuggestCommand(&decoder) },
        .prune_history => .{ .prune_history = try history.decodePruneHistory(&decoder) },
        .read_history_output => .{ .read_history_output = try GenericDerived(ReadHistoryOutputType).decode(&decoder) },
        .history_stats => .{ .history_stats = try history.decodeHistoryStatsQuery(&decoder) },
        .request_pane_focus => .{ .request_pane_focus = try focus.decodeRequestPaneFocus(&decoder) },
        .complete_pane_focus => .{ .complete_pane_focus = try focus.decodeCompletePaneFocus(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn decodeServer(payload: []const u8) !ServerMessage {
    var decoder = DecoderType.init(payload);
    const tag = try decodeTag(tags.ServerTag, try decoder.readByte());
    const message: ServerMessage = switch (tag) {
        .pane_opened => .{ .pane_opened = try GenericDerived(PaneOpenedType).decode(&decoder) },
        .pane_frame => .{ .pane_frame = try frame.decodeBody(&decoder) },
        .pane_exited => .{ .pane_exited = try GenericDerived(PaneExitedType).decode(&decoder) },
        .request_failed => .{ .request_failed = try runtime.decodeRequestFailed(&decoder) },
        .runtime_stopping => .{ .runtime_stopping = {} },
        .tab_snapshot => .{
            .tab_snapshot = try tab.decodeTabSnapshot(&decoder),
        },
        .history_results => .{ .history_results = try history.decodeHistoryResults(&decoder) },
        .workspace_snapshot => .{
            .workspace_snapshot = try workspace.decodeWorkspaceSnapshot(&decoder),
        },
        .tab_created => .{ .tab_created = try tab.decodeTabCreated(&decoder) },
        .tab_renamed => .{ .tab_renamed = try tab.decodeTabRenamed(&decoder) },
        .tab_closed => .{ .tab_closed = try GenericDerived(TabClosedType).decode(&decoder) },
        .tab_moved => .{ .tab_moved = try GenericDerived(TabMovedType).decode(&decoder) },
        .graphics_snapshot => .{ .graphics_snapshot = try graphics_bodies.decodeSnapshot(&decoder) },
        .graphics_image => .{ .graphics_image = try graphics_bodies.decodeImage(&decoder) },
        .graphics_image_chunk => .{ .graphics_image_chunk = try graphics_bodies.decodeImageChunk(&decoder) },
        .graphics_placement => .{ .graphics_placement = try graphics_bodies.decodePlacement(&decoder) },
        .graphics_delete_image => .{ .graphics_delete_image = try graphics_bodies.decodeDeleteImage(&decoder) },
        .graphics_delete_placement => .{ .graphics_delete_placement = try graphics_bodies.decodeDeletePlacement(&decoder) },
        .resync_required => .{ .resync_required = try GenericDerived(ResyncRequiredType).decode(&decoder) },
        .graphics_shared_image => .{ .graphics_shared_image = try graphics_bodies.decodeSharedImage(&decoder) },
        .proxy_status => .{ .proxy_status = try GenericDerived(ProxyStatusType).decode(&decoder) },
        .agent_snapshot => .{ .agent_snapshot = try agent.decodeAgentSnapshot(&decoder) },
        .system_metrics => .{ .system_metrics = try GenericDerived(SystemMetricsType).decode(&decoder) },
        .workspace_list => .{ .workspace_list = try workspace.decodeWorkspaceList(&decoder) },
        .pane_cwd => .{ .pane_cwd = try pane.decodePaneCwd(&decoder) },
        .pane_foreground => .{ .pane_foreground = try pane.decodePaneForeground(&decoder) },
        .pane_clipboard => .{ .pane_clipboard = try pane.decodePaneClipboard(&decoder) },
        .notification => .{ .notification = try notification.decodeNotification(&decoder) },
        .notification_shown => .{
            .notification_shown = try GenericDerived(NotificationShownType).decode(&decoder),
        },
        .agent_sound => .{ .agent_sound = try agent.decodeAgentSound(&decoder) },
        .client_layout_snapshot => .{
            .client_layout_snapshot = try layout.decodeClientLayoutSnapshot(&decoder),
        },
        .pane_text => .{ .pane_text = try pane.decodePaneText(&decoder) },
        .request_completed => .{ .request_completed = try GenericDerived(RequestCompletedType).decode(&decoder) },
        .pane_title => .{ .pane_title = try pane.decodePaneTitle(&decoder) },
        .pane_matches => .{ .pane_matches = try pane.decodePaneMatches(&decoder) },
        .history_pruned => .{ .history_pruned = try GenericDerived(HistoryPrunedType).decode(&decoder) },
        .command_suggestion => .{ .command_suggestion = try suggestion.decodeCommandSuggestion(&decoder) },
        .history_output => .{ .history_output = try history.decodeHistoryOutput(&decoder) },
        .history_stats_result => .{ .history_stats_result = try history.decodeHistoryStats(&decoder) },
        .pane_focus_command => .{ .pane_focus_command = try focus.decodePaneFocusCommand(&decoder) },
        .pane_focus_result => .{ .pane_focus_result = try focus.decodePaneFocusResult(&decoder) },
        .pane_progress => .{ .pane_progress = try pane.decodePaneProgress(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

fn decodeTag(comptime Tag: type, value: u8) error{UnknownMessage}!Tag {
    return std.enums.fromInt(Tag, value) orelse error.UnknownMessage;
}
