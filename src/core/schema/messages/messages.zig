//! Application messages grouped by the part of the product they serve, and
//! the two dispatchers that turn a tagged payload into one of them.
//!
//! Every domain file owns its message types, their tagged encoders and the
//! body decoders; `decodeClient` and `decodeServer` here own the tag switch
//! and the trailing-bytes check, so a payload is never accepted with data
//! after its message.

const agent_thread = @import("agent_thread.zig");
const agent_history = @import("agent_history.zig");
const OpenEditor = @import("OpenEditor.zig");
const EditorOpened = @import("EditorOpened.zig");
const editor = @import("editor.zig");
const OpenPaneView = @import("OpenPaneView.zig");
const PaneInput = @import("PaneInput.zig");
const PaneResize = @import("PaneResize.zig");
const FrameAck = @import("FrameAck.zig");
const RequestSnapshot = @import("RequestSnapshot.zig");
const DetachPane = @import("DetachPane.zig");
const RequestTabSnapshot = @import("RequestTabSnapshot.zig");
const CreatePaneView = @import("CreatePaneView.zig");
const ClosePane = @import("ClosePane.zig");
const QueryHistory = @import("QueryHistory.zig");
const RequestWorkspaceSnapshot = @import("RequestWorkspaceSnapshot.zig");
const CreateTabView = @import("CreateTabView.zig");
const RenameTab = @import("RenameTab.zig");
const CloseTab = @import("CloseTab.zig");
const MoveTab = @import("MoveTab.zig");
const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");
const GraphicsCredit = @import("GraphicsCredit.zig");
const ConfigureGraphics = @import("ConfigureGraphics.zig");
const TerminalColors = @import("../TerminalColors.zig");
const RequestRuntimeState = @import("RequestRuntimeState.zig");
const CreateWorkspaceView = @import("CreateWorkspaceView.zig");
const RenameWorkspace = @import("RenameWorkspace.zig");
const SetPaneViewport = @import("SetPaneViewport.zig");
const CopySelection = @import("CopySelection.zig");
const ShowNotification = @import("ShowNotification.zig");
const AcknowledgeAgent = @import("AcknowledgeAgent.zig");
const QueryAgents = @import("QueryAgents.zig");
const ReadPane = @import("ReadPane.zig");
const SendPaneText = @import("SendPaneText.zig");
const ReportAgentSession = @import("ReportAgentSession.zig");
const ReportAgent = @import("ReportAgent.zig");
const ReportAgentCommand = @import("ReportAgentCommand.zig");
const ReportAgentTitle = @import("ReportAgentTitle.zig");
const SearchPane = @import("SearchPane.zig");
const ImportHistoryView = @import("ImportHistoryView.zig");
const DeleteHistory = @import("DeleteHistory.zig");
const SuggestCommand = @import("SuggestCommand.zig");
const PruneHistory = @import("PruneHistory.zig");
const ReadHistoryOutput = @import("ReadHistoryOutput.zig");
const HistoryStatsQuery = @import("HistoryStatsQuery.zig");
const ClientLayoutUpdateView = @import("ClientLayoutUpdateView.zig");
const RequestPaneFocus = @import("RequestPaneFocus.zig");
const CompletePaneFocus = @import("CompletePaneFocus.zig");
const PaneOpened = @import("PaneOpened.zig");
const FrameView = @import("../FrameView.zig");
const PaneExited = @import("PaneExited.zig");
const RequestFailed = @import("RequestFailed.zig");
const TabSnapshotView = @import("TabSnapshotView.zig");
const HistoryResultsView = @import("HistoryResultsView.zig");
const WorkspaceSnapshotView = @import("WorkspaceSnapshotView.zig");
const TabCreated = @import("TabCreated.zig");
const TabRenamed = @import("TabRenamed.zig");
const TabClosed = @import("TabClosed.zig");
const TabMoved = @import("TabMoved.zig");
const Snapshot = @import("../Snapshot.zig");
const Image = @import("../Image.zig");
const ImageChunk = @import("../ImageChunk.zig");
const Placement = @import("../Placement.zig");
const DeleteImage = @import("../DeleteImage.zig");
const DeletePlacement = @import("../DeletePlacement.zig");
const ResyncRequired = @import("ResyncRequired.zig");
const SharedImage = @import("../SharedImage.zig");
const ProxyStatus = @import("ProxyStatus.zig");
const AgentSnapshotView = @import("AgentSnapshotView.zig");
const SystemMetrics = @import("SystemMetrics.zig");
const WorkspaceListView = @import("WorkspaceListView.zig");
const PaneCwd = @import("PaneCwd.zig");
const PaneForeground = @import("PaneForeground.zig");
const PaneClipboard = @import("PaneClipboard.zig");
const Notification = @import("Notification.zig");
const NotificationShown = @import("NotificationShown.zig");
const AgentSoundNotification = @import("../AgentSoundNotification.zig");
const ClientLayoutSnapshotView = @import("ClientLayoutSnapshotView.zig");
const PaneText = @import("PaneText.zig");
const RequestCompleted = @import("RequestCompleted.zig");
const PaneTitle = @import("PaneTitle.zig");
const PaneMatchesView = @import("PaneMatchesView.zig");
const HistoryPruned = @import("HistoryPruned.zig");
const CommandSuggestion = @import("CommandSuggestion.zig");
const HistoryOutput = @import("HistoryOutput.zig");
const HistoryStatsView = @import("HistoryStatsView.zig");
const PaneFocusCommand = @import("PaneFocusCommand.zig");
const PaneFocusResult = @import("PaneFocusResult.zig");
const PaneProgress = @import("PaneProgress.zig");
const Decoder = @import("../Decoder.zig");
const tags = @import("tags.zig");
const pane = @import("pane.zig");
const GenericDerived = @import("../GenericDerived.zig").Type;
const history = @import("history.zig");
const tab = @import("tab.zig");
const runtime = @import("runtime.zig");
const workspace = @import("workspace.zig");
const clients = @import("clients.zig");
const DetachClient = @import("DetachClient.zig");
const QueryClients = @import("QueryClients.zig");
const ClientList = @import("../../ClientList.zig");
const notification = @import("notification_support.zig");
const layout = @import("layout.zig");
const agent = @import("agent.zig");
const suggestion = @import("suggestion.zig");
const focus = @import("focus.zig");
const frame = @import("../frame_support.zig");
const graphics_bodies = @import("../graphics.zig");
const ClientCommand = @import("ClientCommand.zig");
const client_commands = @import("client_commands.zig");
const std = @import("std");

pub const ClientMessage = union(enum) {
    query_clients: QueryClients,
    detach_client: DetachClient,
    request_client_command: ClientCommand,
    complete_client_command: ClientCommand,

    query_change_review: @import("QueryChangeReview.zig"),
    change_review_command: @import("ChangeReviewCommand.zig"),
    report_change_review_sample: @import("ReportChangeReviewSample.zig"),
    open_pane: OpenPaneView,
    pane_input: PaneInput,
    pane_resize: PaneResize,
    frame_ack: FrameAck,
    request_snapshot: RequestSnapshot,
    detach_pane: DetachPane,
    runtime_stop: void,
    request_tab_snapshot: RequestTabSnapshot,
    create_pane: CreatePaneView,
    close_pane: ClosePane,
    query_history: QueryHistory,
    request_workspace_snapshot: RequestWorkspaceSnapshot,
    create_tab: CreateTabView,
    agent_prompt: @import("AgentPrompt.zig"),
    agent_interrupt: @import("AgentInterrupt.zig"),
    agent_resume: @import("AgentResume.zig"),
    agent_approval: @import("AgentApproval.zig"),
    query_agent_thread: @import("QueryAgentThread.zig"),
    query_agent_history: @import("QueryAgentHistory.zig"),
    rename_tab: RenameTab,
    close_tab: CloseTab,
    move_tab: MoveTab,
    request_graphics_snapshot: RequestGraphicsSnapshot,
    graphics_credit: GraphicsCredit,
    configure_graphics: ConfigureGraphics,
    configure_terminal_colors: TerminalColors,
    request_runtime_state: RequestRuntimeState,
    create_workspace: CreateWorkspaceView,
    rename_workspace: RenameWorkspace,
    set_pane_viewport: SetPaneViewport,
    copy_selection: CopySelection,
    show_notification: ShowNotification,
    acknowledge_agent: AcknowledgeAgent,
    query_agents: QueryAgents,
    read_pane: ReadPane,
    send_pane_text: SendPaneText,
    report_agent_session: ReportAgentSession,
    report_agent: ReportAgent,
    report_agent_command: ReportAgentCommand,
    report_agent_title: ReportAgentTitle,
    search_pane: SearchPane,
    import_history: ImportHistoryView,
    delete_history: DeleteHistory,
    suggest_command: SuggestCommand,
    prune_history: PruneHistory,
    read_history_output: ReadHistoryOutput,
    history_stats: HistoryStatsQuery,
    update_client_layout: ClientLayoutUpdateView,
    request_pane_focus: RequestPaneFocus,
    open_editor: OpenEditor,
    complete_pane_focus: CompletePaneFocus,
};

const ChangeReviewChanged = @import("ChangeReviewChanged.zig");
const change_review = @import("change_review.zig");

pub const ServerMessage = union(enum) {
    client_list: ClientList,
    client_command: ClientCommand,
    client_command_result: ClientCommand,

    change_review_changed: ChangeReviewChanged,
    change_review_snapshot: @import("ChangeReviewSnapshotView.zig"),
    pane_opened: PaneOpened,
    agent_thread_snapshot: agent_thread.SnapshotView,
    agent_history_page: @import("AgentHistoryPageView.zig"),
    pane_frame: FrameView,
    pane_exited: PaneExited,
    request_failed: RequestFailed,
    runtime_stopping: void,
    tab_snapshot: TabSnapshotView,
    history_results: HistoryResultsView,
    workspace_snapshot: WorkspaceSnapshotView,
    tab_created: TabCreated,
    tab_renamed: TabRenamed,
    tab_closed: TabClosed,
    tab_moved: TabMoved,
    graphics_snapshot: Snapshot,
    graphics_image: Image,
    graphics_image_chunk: ImageChunk,
    graphics_placement: Placement,
    graphics_delete_image: DeleteImage,
    graphics_delete_placement: DeletePlacement,
    resync_required: ResyncRequired,
    graphics_shared_image: SharedImage,
    proxy_status: ProxyStatus,
    agent_snapshot: AgentSnapshotView,
    system_metrics: SystemMetrics,
    workspace_list: WorkspaceListView,
    pane_cwd: PaneCwd,
    pane_foreground: PaneForeground,
    pane_clipboard: PaneClipboard,
    notification: Notification,
    notification_shown: NotificationShown,
    agent_sound: AgentSoundNotification,
    client_layout_snapshot: ClientLayoutSnapshotView,
    pane_text: PaneText,
    request_completed: RequestCompleted,
    pane_title: PaneTitle,
    pane_matches: PaneMatchesView,
    history_pruned: HistoryPruned,
    command_suggestion: CommandSuggestion,
    history_output: HistoryOutput,
    history_stats_result: HistoryStatsView,
    pane_focus_command: PaneFocusCommand,
    pane_focus_result: PaneFocusResult,
    editor_opened: EditorOpened,
    pane_progress: PaneProgress,
};

pub fn decodeClient(payload: []const u8) !ClientMessage {
    var decoder = Decoder.init(payload);
    const tag = try decodeTag(tags.ClientTag, try decoder.readByte());
    const message: ClientMessage = switch (tag) {
        .open_pane => .{ .open_pane = try pane.decodeOpenPane(&decoder) },
        .pane_input => .{ .pane_input = try pane.decodePaneInput(&decoder) },
        .pane_resize => .{ .pane_resize = try GenericDerived(PaneResize).decode(&decoder) },
        .frame_ack => .{ .frame_ack = try GenericDerived(FrameAck).decode(&decoder) },
        .request_snapshot => .{ .request_snapshot = try GenericDerived(RequestSnapshot).decode(&decoder) },
        .detach_pane => .{ .detach_pane = try GenericDerived(DetachPane).decode(&decoder) },
        .runtime_stop => .{ .runtime_stop = {} },
        .request_tab_snapshot => .{
            .request_tab_snapshot = try GenericDerived(RequestTabSnapshot).decode(&decoder),
        },
        .create_pane => .{ .create_pane = try pane.decodeCreatePane(&decoder) },
        .close_pane => .{ .close_pane = try GenericDerived(ClosePane).decode(&decoder) },
        .query_history => .{ .query_history = try history.decodeQueryHistory(&decoder) },
        .request_workspace_snapshot => .{
            .request_workspace_snapshot = try GenericDerived(RequestWorkspaceSnapshot).decode(&decoder),
        },
        .create_tab => .{ .create_tab = try tab.decodeCreateTab(&decoder) },
        .agent_prompt => .{ .agent_prompt = try agent_thread.decodeAgentPrompt(&decoder) },
        .agent_interrupt => .{ .agent_interrupt = try agent_thread.decodeControl(@import("AgentInterrupt.zig"), &decoder) },
        .agent_resume => .{ .agent_resume = try agent_thread.decodeControl(@import("AgentResume.zig"), &decoder) },
        .agent_approval => .{ .agent_approval = try agent_thread.decodeControl(@import("AgentApproval.zig"), &decoder) },
        .query_change_review => .{ .query_change_review = try change_review.decode(@import("QueryChangeReview.zig"), &decoder) },
        .change_review_command => .{ .change_review_command = try change_review.decode(@import("ChangeReviewCommand.zig"), &decoder) },
        .report_change_review_sample => .{ .report_change_review_sample = try change_review.decode(@import("ReportChangeReviewSample.zig"), &decoder) },
        .query_agent_thread => .{ .query_agent_thread = try agent_thread.decodeControl(@import("QueryAgentThread.zig"), &decoder) },
        .query_agent_history => .{ .query_agent_history = try agent_history.decodeQueryAgentHistory(&decoder) },
        .rename_tab => .{ .rename_tab = try tab.decodeRenameTab(&decoder) },
        .close_tab => .{ .close_tab = try GenericDerived(CloseTab).decode(&decoder) },
        .move_tab => .{ .move_tab = try GenericDerived(MoveTab).decode(&decoder) },
        .request_graphics_snapshot => .{
            .request_graphics_snapshot = try GenericDerived(RequestGraphicsSnapshot).decode(&decoder),
        },
        .graphics_credit => .{
            .graphics_credit = try GenericDerived(GraphicsCredit).decode(&decoder),
        },
        .configure_graphics => .{
            .configure_graphics = try GenericDerived(ConfigureGraphics).decode(&decoder),
        },
        .configure_terminal_colors => .{ .configure_terminal_colors = try runtime.decodeConfigureTerminalColors(&decoder) },
        .request_runtime_state => .{ .request_runtime_state = try runtime.decodeRequestRuntimeState(&decoder) },
        .create_workspace => .{ .create_workspace = try workspace.decodeCreateWorkspace(&decoder) },
        .rename_workspace => .{ .rename_workspace = try workspace.decodeRenameWorkspace(&decoder) },
        .set_pane_viewport => .{
            .set_pane_viewport = try GenericDerived(SetPaneViewport).decode(&decoder),
        },
        .copy_selection => .{
            .copy_selection = try GenericDerived(CopySelection).decode(&decoder),
        },
        .show_notification => .{ .show_notification = try notification.decodeShowNotification(&decoder) },
        .update_client_layout => .{ .update_client_layout = try layout.decodeClientLayoutUpdate(&decoder) },
        .acknowledge_agent => .{
            .acknowledge_agent = try GenericDerived(AcknowledgeAgent).decode(&decoder),
        },
        .request_client_command => .{ .request_client_command = try client_commands.decode(&decoder) },
        .complete_client_command => .{ .complete_client_command = try client_commands.decode(&decoder) },
        .detach_client => .{ .detach_client = try clients.decodeDetachClient(&decoder) },
        .query_clients => .{ .query_clients = try clients.decodeQueryClients(&decoder) },
        .query_agents => .{ .query_agents = try GenericDerived(QueryAgents).decode(&decoder) },
        .read_pane => .{ .read_pane = try GenericDerived(ReadPane).decode(&decoder) },
        .send_pane_text => .{ .send_pane_text = try pane.decodeSendPaneText(&decoder) },
        .report_agent_session => .{ .report_agent_session = try agent.decodeReportAgentSession(&decoder) },
        .report_agent => .{ .report_agent = try agent.decodeReportAgent(&decoder) },
        .report_agent_command => .{ .report_agent_command = try agent.decodeReportAgentCommand(&decoder) },
        .report_agent_title => .{ .report_agent_title = try agent.decodeReportAgentTitle(&decoder) },
        .search_pane => .{ .search_pane = try pane.decodeSearchPane(&decoder) },
        .import_history => .{ .import_history = try history.decodeImportHistory(&decoder) },
        .delete_history => .{ .delete_history = try GenericDerived(DeleteHistory).decode(&decoder) },
        .suggest_command => .{ .suggest_command = try suggestion.decodeSuggestCommand(&decoder) },
        .prune_history => .{ .prune_history = try history.decodePruneHistory(&decoder) },
        .read_history_output => .{ .read_history_output = try GenericDerived(ReadHistoryOutput).decode(&decoder) },
        .history_stats => .{ .history_stats = try history.decodeHistoryStatsQuery(&decoder) },
        .open_editor => .{ .open_editor = try editor.decodeOpenEditor(&decoder) },
        .request_pane_focus => .{ .request_pane_focus = try focus.decodeRequestPaneFocus(&decoder) },
        .complete_pane_focus => .{ .complete_pane_focus = try focus.decodeCompletePaneFocus(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn decodeServer(payload: []const u8) !ServerMessage {
    var decoder = Decoder.init(payload);
    const tag = try decodeTag(tags.ServerTag, try decoder.readByte());
    const message: ServerMessage = switch (tag) {
        .change_review_changed => .{ .change_review_changed = try change_review.decode(ChangeReviewChanged, &decoder) },
        .change_review_snapshot => .{ .change_review_snapshot = try change_review.decode(@import("ChangeReviewSnapshotView.zig"), &decoder) },
        .agent_thread_snapshot => .{ .agent_thread_snapshot = try agent_thread.decodeAgentThreadSnapshot(&decoder) },
        .agent_history_page => .{ .agent_history_page = try agent_history.decodeAgentHistoryPage(&decoder) },
        .pane_opened => .{ .pane_opened = try GenericDerived(PaneOpened).decode(&decoder) },
        .pane_frame => .{ .pane_frame = try frame.decodeBody(&decoder) },
        .pane_exited => .{ .pane_exited = try GenericDerived(PaneExited).decode(&decoder) },
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
        .tab_closed => .{ .tab_closed = try GenericDerived(TabClosed).decode(&decoder) },
        .tab_moved => .{ .tab_moved = try GenericDerived(TabMoved).decode(&decoder) },
        .graphics_snapshot => .{ .graphics_snapshot = try graphics_bodies.decodeSnapshot(&decoder) },
        .graphics_image => .{ .graphics_image = try graphics_bodies.decodeImage(&decoder) },
        .graphics_image_chunk => .{ .graphics_image_chunk = try graphics_bodies.decodeImageChunk(&decoder) },
        .graphics_placement => .{ .graphics_placement = try graphics_bodies.decodePlacement(&decoder) },
        .graphics_delete_image => .{ .graphics_delete_image = try graphics_bodies.decodeDeleteImage(&decoder) },
        .graphics_delete_placement => .{ .graphics_delete_placement = try graphics_bodies.decodeDeletePlacement(&decoder) },
        .resync_required => .{ .resync_required = try GenericDerived(ResyncRequired).decode(&decoder) },
        .graphics_shared_image => .{ .graphics_shared_image = try graphics_bodies.decodeSharedImage(&decoder) },
        .proxy_status => .{ .proxy_status = try GenericDerived(ProxyStatus).decode(&decoder) },
        .client_command => .{ .client_command = try client_commands.decode(&decoder) },
        .client_command_result => .{ .client_command_result = try client_commands.decode(&decoder) },
        .client_list => .{ .client_list = try clients.decodeClientList(&decoder) },
        .agent_snapshot => .{ .agent_snapshot = try agent.decodeAgentSnapshot(&decoder) },
        .system_metrics => .{ .system_metrics = try GenericDerived(SystemMetrics).decode(&decoder) },
        .workspace_list => .{ .workspace_list = try workspace.decodeWorkspaceList(&decoder) },
        .pane_cwd => .{ .pane_cwd = try pane.decodePaneCwd(&decoder) },
        .pane_foreground => .{ .pane_foreground = try pane.decodePaneForeground(&decoder) },
        .pane_clipboard => .{ .pane_clipboard = try pane.decodePaneClipboard(&decoder) },
        .notification => .{ .notification = try notification.decodeNotification(&decoder) },
        .notification_shown => .{
            .notification_shown = try GenericDerived(NotificationShown).decode(&decoder),
        },
        .agent_sound => .{ .agent_sound = try agent.decodeAgentSound(&decoder) },
        .client_layout_snapshot => .{
            .client_layout_snapshot = try layout.decodeClientLayoutSnapshot(&decoder),
        },
        .pane_text => .{ .pane_text = try pane.decodePaneText(&decoder) },
        .request_completed => .{ .request_completed = try GenericDerived(RequestCompleted).decode(&decoder) },
        .pane_title => .{ .pane_title = try pane.decodePaneTitle(&decoder) },
        .pane_matches => .{ .pane_matches = try pane.decodePaneMatches(&decoder) },
        .history_pruned => .{ .history_pruned = try GenericDerived(HistoryPruned).decode(&decoder) },
        .command_suggestion => .{ .command_suggestion = try suggestion.decodeCommandSuggestion(&decoder) },
        .history_output => .{ .history_output = try history.decodeHistoryOutput(&decoder) },
        .history_stats_result => .{ .history_stats_result = try history.decodeHistoryStats(&decoder) },
        .pane_focus_command => .{ .pane_focus_command = try focus.decodePaneFocusCommand(&decoder) },
        .editor_opened => .{ .editor_opened = try editor.decodeEditorOpened(&decoder) },
        .pane_focus_result => .{ .pane_focus_result = try focus.decodePaneFocusResult(&decoder) },
        .pane_progress => .{ .pane_progress = try pane.decodePaneProgress(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

fn decodeTag(comptime Tag: type, value: u8) error{UnknownMessage}!Tag {
    return std.enums.fromInt(Tag, value) orelse error.UnknownMessage;
}
