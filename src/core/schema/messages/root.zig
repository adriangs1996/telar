//! Application messages grouped by the part of the product they serve, and
//! the two dispatchers that turn a tagged payload into one of them.
//!
//! Every domain file owns its message types, their tagged encoders and the
//! body decoders; `decodeClient` and `decodeServer` here own the tag switch
//! and the trailing-bytes check, so a payload is never accepted with data
//! after its message.

const std = @import("std");
const wire = @import("../wire.zig");
const codec = @import("../codec.zig");
const frame = @import("../frame.zig");
const graphics_bodies = @import("../graphics.zig");
const types = @import("../types.zig");

pub const tags = @import("tags.zig");
pub const launch = @import("launch.zig");
pub const pane = @import("pane.zig");
pub const focus = @import("focus.zig");
pub const workspace = @import("workspace.zig");
pub const tab = @import("tab.zig");
pub const history = @import("history.zig");
pub const suggestion = @import("suggestion.zig");
pub const agent = @import("agent.zig");
pub const notification = @import("notification.zig");
pub const layout = @import("layout.zig");
pub const runtime = @import("runtime.zig");
pub const graphics = @import("graphics.zig");

pub const ClientTag = tags.ClientTag;
pub const ServerTag = tags.ServerTag;

const Derived = codec.Derived;

pub const ClientMessage = union(enum) {
    open_pane: pane.OpenPaneView,
    pane_input: pane.PaneInput,
    pane_resize: pane.PaneResize,
    frame_ack: pane.FrameAck,
    request_snapshot: pane.RequestSnapshot,
    detach_pane: pane.DetachPane,
    runtime_stop: void,
    request_tab_snapshot: tab.RequestTabSnapshot,
    create_pane: pane.CreatePaneView,
    close_pane: pane.ClosePane,
    query_history: history.QueryHistory,
    request_workspace_snapshot: workspace.RequestWorkspaceSnapshot,
    create_tab: tab.CreateTabView,
    rename_tab: tab.RenameTab,
    close_tab: tab.CloseTab,
    move_tab: tab.MoveTab,
    request_graphics_snapshot: graphics.RequestGraphicsSnapshot,
    graphics_credit: graphics.GraphicsCredit,
    configure_graphics: graphics.ConfigureGraphics,
    request_runtime_state: runtime.RequestRuntimeState,
    create_workspace: workspace.CreateWorkspaceView,
    rename_workspace: workspace.RenameWorkspace,
    set_pane_viewport: pane.SetPaneViewport,
    copy_selection: pane.CopySelection,
    show_notification: notification.ShowNotification,
    acknowledge_agent: agent.AcknowledgeAgent,
    query_agents: agent.QueryAgents,
    read_pane: pane.ReadPane,
    send_pane_text: pane.SendPaneText,
    report_agent_session: agent.ReportAgentSession,
    report_agent: agent.ReportAgent,
    report_agent_command: agent.ReportAgentCommand,
    report_agent_title: agent.ReportAgentTitle,
    search_pane: pane.SearchPane,
    import_history: history.ImportHistoryView,
    delete_history: history.DeleteHistory,
    suggest_command: suggestion.SuggestCommand,
    prune_history: history.PruneHistory,
    read_history_output: history.ReadHistoryOutput,
    history_stats: history.HistoryStatsQuery,
    update_client_layout: layout.ClientLayoutUpdateView,
    request_pane_focus: focus.RequestPaneFocus,
    complete_pane_focus: focus.CompletePaneFocus,
};

pub const ServerMessage = union(enum) {
    pane_opened: pane.PaneOpened,
    pane_frame: frame.FrameView,
    pane_exited: pane.PaneExited,
    request_failed: runtime.RequestFailed,
    runtime_stopping: void,
    tab_snapshot: tab.TabSnapshotView,
    history_results: history.HistoryResultsView,
    workspace_snapshot: workspace.WorkspaceSnapshotView,
    tab_created: tab.TabCreated,
    tab_renamed: tab.TabRenamed,
    tab_closed: tab.TabClosed,
    tab_moved: tab.TabMoved,
    graphics_snapshot: graphics_bodies.Snapshot,
    graphics_image: graphics_bodies.Image,
    graphics_image_chunk: graphics_bodies.ImageChunk,
    graphics_placement: graphics_bodies.Placement,
    graphics_delete_image: graphics_bodies.DeleteImage,
    graphics_delete_placement: graphics_bodies.DeletePlacement,
    resync_required: workspace.ResyncRequired,
    graphics_shared_image: graphics_bodies.SharedImage,
    proxy_status: runtime.ProxyStatus,
    agent_snapshot: agent.AgentSnapshotView,
    system_metrics: runtime.SystemMetrics,
    workspace_list: workspace.WorkspaceListView,
    pane_cwd: pane.PaneCwd,
    pane_foreground: pane.PaneForeground,
    pane_clipboard: pane.PaneClipboard,
    notification: notification.Notification,
    notification_shown: notification.NotificationShown,
    agent_sound: types.AgentSoundNotification,
    client_layout_snapshot: layout.ClientLayoutSnapshotView,
    pane_text: pane.PaneText,
    request_completed: runtime.RequestCompleted,
    pane_title: pane.PaneTitle,
    pane_matches: pane.PaneMatchesView,
    history_pruned: history.HistoryPruned,
    command_suggestion: suggestion.CommandSuggestion,
    history_output: history.HistoryOutput,
    history_stats_result: history.HistoryStatsView,
    pane_focus_command: focus.PaneFocusCommand,
    pane_focus_result: focus.PaneFocusResult,
    pane_progress: pane.PaneProgress,
};

pub fn decodeClient(payload: []const u8) !ClientMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeTag(ClientTag, try decoder.readByte());
    const message: ClientMessage = switch (tag) {
        .open_pane => .{ .open_pane = try pane.decodeOpenPane(&decoder) },
        .pane_input => .{ .pane_input = try pane.decodePaneInput(&decoder) },
        .pane_resize => .{ .pane_resize = try Derived(pane.PaneResize).decode(&decoder) },
        .frame_ack => .{ .frame_ack = try Derived(pane.FrameAck).decode(&decoder) },
        .request_snapshot => .{ .request_snapshot = try Derived(pane.RequestSnapshot).decode(&decoder) },
        .detach_pane => .{ .detach_pane = try Derived(pane.DetachPane).decode(&decoder) },
        .runtime_stop => .{ .runtime_stop = {} },
        .request_tab_snapshot => .{
            .request_tab_snapshot = try Derived(tab.RequestTabSnapshot).decode(&decoder),
        },
        .create_pane => .{ .create_pane = try pane.decodeCreatePane(&decoder) },
        .close_pane => .{ .close_pane = try Derived(pane.ClosePane).decode(&decoder) },
        .query_history => .{ .query_history = try history.decodeQueryHistory(&decoder) },
        .request_workspace_snapshot => .{
            .request_workspace_snapshot = try Derived(workspace.RequestWorkspaceSnapshot).decode(&decoder),
        },
        .create_tab => .{ .create_tab = try tab.decodeCreateTab(&decoder) },
        .rename_tab => .{ .rename_tab = try tab.decodeRenameTab(&decoder) },
        .close_tab => .{ .close_tab = try Derived(tab.CloseTab).decode(&decoder) },
        .move_tab => .{ .move_tab = try Derived(tab.MoveTab).decode(&decoder) },
        .request_graphics_snapshot => .{
            .request_graphics_snapshot = try Derived(graphics.RequestGraphicsSnapshot).decode(&decoder),
        },
        .graphics_credit => .{
            .graphics_credit = try Derived(graphics.GraphicsCredit).decode(&decoder),
        },
        .configure_graphics => .{
            .configure_graphics = try Derived(graphics.ConfigureGraphics).decode(&decoder),
        },
        .request_runtime_state => .{ .request_runtime_state = try runtime.decodeRequestRuntimeState(&decoder) },
        .create_workspace => .{ .create_workspace = try workspace.decodeCreateWorkspace(&decoder) },
        .rename_workspace => .{ .rename_workspace = try workspace.decodeRenameWorkspace(&decoder) },
        .set_pane_viewport => .{
            .set_pane_viewport = try Derived(pane.SetPaneViewport).decode(&decoder),
        },
        .copy_selection => .{
            .copy_selection = try Derived(pane.CopySelection).decode(&decoder),
        },
        .show_notification => .{ .show_notification = try notification.decodeShowNotification(&decoder) },
        .update_client_layout => .{ .update_client_layout = try layout.decodeClientLayoutUpdate(&decoder) },
        .acknowledge_agent => .{
            .acknowledge_agent = try Derived(agent.AcknowledgeAgent).decode(&decoder),
        },
        .query_agents => .{ .query_agents = try Derived(agent.QueryAgents).decode(&decoder) },
        .read_pane => .{ .read_pane = try Derived(pane.ReadPane).decode(&decoder) },
        .send_pane_text => .{ .send_pane_text = try pane.decodeSendPaneText(&decoder) },
        .report_agent_session => .{ .report_agent_session = try agent.decodeReportAgentSession(&decoder) },
        .report_agent => .{ .report_agent = try agent.decodeReportAgent(&decoder) },
        .report_agent_command => .{ .report_agent_command = try agent.decodeReportAgentCommand(&decoder) },
        .report_agent_title => .{ .report_agent_title = try agent.decodeReportAgentTitle(&decoder) },
        .search_pane => .{ .search_pane = try pane.decodeSearchPane(&decoder) },
        .import_history => .{ .import_history = try history.decodeImportHistory(&decoder) },
        .delete_history => .{ .delete_history = try Derived(history.DeleteHistory).decode(&decoder) },
        .suggest_command => .{ .suggest_command = try suggestion.decodeSuggestCommand(&decoder) },
        .prune_history => .{ .prune_history = try history.decodePruneHistory(&decoder) },
        .read_history_output => .{ .read_history_output = try Derived(history.ReadHistoryOutput).decode(&decoder) },
        .history_stats => .{ .history_stats = try history.decodeHistoryStatsQuery(&decoder) },
        .request_pane_focus => .{ .request_pane_focus = try focus.decodeRequestPaneFocus(&decoder) },
        .complete_pane_focus => .{ .complete_pane_focus = try focus.decodeCompletePaneFocus(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn decodeServer(payload: []const u8) !ServerMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeTag(ServerTag, try decoder.readByte());
    const message: ServerMessage = switch (tag) {
        .pane_opened => .{ .pane_opened = try Derived(pane.PaneOpened).decode(&decoder) },
        .pane_frame => .{ .pane_frame = try frame.decodeBody(&decoder) },
        .pane_exited => .{ .pane_exited = try Derived(pane.PaneExited).decode(&decoder) },
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
        .tab_closed => .{ .tab_closed = try Derived(tab.TabClosed).decode(&decoder) },
        .tab_moved => .{ .tab_moved = try Derived(tab.TabMoved).decode(&decoder) },
        .graphics_snapshot => .{ .graphics_snapshot = try graphics_bodies.decodeSnapshot(&decoder) },
        .graphics_image => .{ .graphics_image = try graphics_bodies.decodeImage(&decoder) },
        .graphics_image_chunk => .{ .graphics_image_chunk = try graphics_bodies.decodeImageChunk(&decoder) },
        .graphics_placement => .{ .graphics_placement = try graphics_bodies.decodePlacement(&decoder) },
        .graphics_delete_image => .{ .graphics_delete_image = try graphics_bodies.decodeDeleteImage(&decoder) },
        .graphics_delete_placement => .{ .graphics_delete_placement = try graphics_bodies.decodeDeletePlacement(&decoder) },
        .resync_required => .{ .resync_required = try Derived(workspace.ResyncRequired).decode(&decoder) },
        .graphics_shared_image => .{ .graphics_shared_image = try graphics_bodies.decodeSharedImage(&decoder) },
        .proxy_status => .{ .proxy_status = try Derived(runtime.ProxyStatus).decode(&decoder) },
        .agent_snapshot => .{ .agent_snapshot = try agent.decodeAgentSnapshot(&decoder) },
        .system_metrics => .{ .system_metrics = try Derived(runtime.SystemMetrics).decode(&decoder) },
        .workspace_list => .{ .workspace_list = try workspace.decodeWorkspaceList(&decoder) },
        .pane_cwd => .{ .pane_cwd = try pane.decodePaneCwd(&decoder) },
        .pane_foreground => .{ .pane_foreground = try pane.decodePaneForeground(&decoder) },
        .pane_clipboard => .{ .pane_clipboard = try pane.decodePaneClipboard(&decoder) },
        .notification => .{ .notification = try notification.decodeNotification(&decoder) },
        .notification_shown => .{
            .notification_shown = try Derived(notification.NotificationShown).decode(&decoder),
        },
        .agent_sound => .{ .agent_sound = try agent.decodeAgentSound(&decoder) },
        .client_layout_snapshot => .{
            .client_layout_snapshot = try layout.decodeClientLayoutSnapshot(&decoder),
        },
        .pane_text => .{ .pane_text = try pane.decodePaneText(&decoder) },
        .request_completed => .{ .request_completed = try Derived(runtime.RequestCompleted).decode(&decoder) },
        .pane_title => .{ .pane_title = try pane.decodePaneTitle(&decoder) },
        .pane_matches => .{ .pane_matches = try pane.decodePaneMatches(&decoder) },
        .history_pruned => .{ .history_pruned = try Derived(history.HistoryPruned).decode(&decoder) },
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
