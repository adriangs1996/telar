//! Exhaustive classification and delegation for decoded client requests.

const std = @import("std");
const ClientMessageType = @import("telar-core").ClientMessage;
const RequestRouterCapture = @import("RequestRouterCapture.zig");
const PaneInputType = @import("telar-core").PaneInput;
const GenericHandlers = @import("GenericHandlers.zig").Type;
const OpenPaneViewType = @import("telar-core").OpenPaneView;
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
const GenericRouter = @import("GenericRouter.zig").Type;
const RequestIdType = @import("telar-core").RequestId;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;

pub const Tag = std.meta.Tag(ClientMessageType);

pub const RequestClass = enum {
    ui,
    control,
};

/// Classifies the first request on a connection without coupling the event
/// loop to individual payload types.
///
/// ```zig
/// const class = classify(std.meta.activeTag(message));
/// ```
pub fn classify(tag: Tag) RequestClass {
    return switch (tag) {
        .runtime_stop,
        .query_history,
        .import_history,
        .delete_history,
        .prune_history,
        .read_history_output,
        .history_stats,
        .show_notification,
        .query_agents,
        .read_pane,
        .send_pane_text,
        .report_agent_session,
        .report_agent,
        .report_agent_command,
        .report_agent_title,
        .request_pane_focus,
        => .control,
        else => .ui,
    };
}

fn captureHandler(comptime tag: Tag, comptime Payload: type) *const fn (*RequestRouterCapture, Payload) anyerror!void {
    return struct {
        fn call(capture: *RequestRouterCapture, payload: Payload) !void {
            capture.calls += 1;
            capture.last = tag;

            if (comptime Payload == PaneInputType) {
                capture.pane_input = payload;
            }

            if (capture.failure == tag) {
                return error.RequestHandlerFailed;
            }
        }
    }.call;
}

fn captureVoidHandler(comptime tag: Tag) *const fn (*RequestRouterCapture) anyerror!void {
    return struct {
        fn call(capture: *RequestRouterCapture) !void {
            capture.calls += 1;
            capture.last = tag;

            if (capture.failure == tag) {
                return error.RequestHandlerFailed;
            }
        }
    }.call;
}

const testing_handlers: GenericHandlers(RequestRouterCapture) = .{
    .open_pane = captureHandler(.open_pane, OpenPaneViewType),
    .pane_input = captureHandler(.pane_input, PaneInputType),
    .pane_resize = captureHandler(.pane_resize, PaneResizeType),
    .frame_ack = captureHandler(.frame_ack, FrameAckType),
    .request_snapshot = captureHandler(.request_snapshot, RequestSnapshotType),
    .detach_pane = captureHandler(.detach_pane, DetachPaneType),
    .runtime_stop = captureVoidHandler(.runtime_stop),
    .request_tab_snapshot = captureHandler(.request_tab_snapshot, RequestTabSnapshotType),
    .create_pane = captureHandler(.create_pane, CreatePaneViewType),
    .close_pane = captureHandler(.close_pane, ClosePaneType),
    .query_history = captureHandler(.query_history, QueryHistoryType),
    .suggest_command = captureHandler(.suggest_command, SuggestCommandType),
    .request_workspace_snapshot = captureHandler(.request_workspace_snapshot, RequestWorkspaceSnapshotType),
    .create_tab = captureHandler(.create_tab, CreateTabViewType),
    .rename_tab = captureHandler(.rename_tab, RenameTabType),
    .close_tab = captureHandler(.close_tab, CloseTabType),
    .move_tab = captureHandler(.move_tab, MoveTabType),
    .request_graphics_snapshot = captureHandler(.request_graphics_snapshot, RequestGraphicsSnapshotType),
    .graphics_credit = captureHandler(.graphics_credit, GraphicsCreditType),
    .configure_graphics = captureHandler(.configure_graphics, ConfigureGraphicsType),
    .configure_terminal_colors = captureHandler(.configure_terminal_colors, TerminalColors),
    .request_runtime_state = captureHandler(.request_runtime_state, RequestRuntimeStateType),
    .create_workspace = captureHandler(.create_workspace, CreateWorkspaceViewType),
    .rename_workspace = captureHandler(.rename_workspace, RenameWorkspaceType),
    .set_pane_viewport = captureHandler(.set_pane_viewport, SetPaneViewportType),
    .copy_selection = captureHandler(.copy_selection, CopySelectionType),
    .show_notification = captureHandler(.show_notification, ShowNotificationType),
    .update_client_layout = captureHandler(.update_client_layout, ClientLayoutUpdateViewType),
    .acknowledge_agent = captureHandler(.acknowledge_agent, AcknowledgeAgentType),
    .query_agents = captureHandler(.query_agents, QueryAgentsType),
    .read_pane = captureHandler(.read_pane, ReadPaneType),
    .send_pane_text = captureHandler(.send_pane_text, SendPaneTextType),
    .report_agent_session = captureHandler(.report_agent_session, ReportAgentSessionType),
    .report_agent = captureHandler(.report_agent, ReportAgentType),
    .report_agent_command = captureHandler(.report_agent_command, ReportAgentCommandType),
    .report_agent_title = captureHandler(.report_agent_title, ReportAgentTitleType),
    .search_pane = captureHandler(.search_pane, SearchPaneType),
    .import_history = captureHandler(.import_history, ImportHistoryViewType),
    .delete_history = captureHandler(.delete_history, DeleteHistoryType),
    .prune_history = captureHandler(.prune_history, PruneHistoryType),
    .read_history_output = captureHandler(.read_history_output, ReadHistoryOutputType),
    .history_stats = captureHandler(.history_stats, HistoryStatsQueryType),
    .request_pane_focus = captureHandler(.request_pane_focus, RequestPaneFocusType),
    .complete_pane_focus = captureHandler(.complete_pane_focus, CompletePaneFocusType),
};

const TestRouter = GenericRouter(RequestRouterCapture, testing_handlers);

fn testingMessages() [@typeInfo(Tag).@"enum".fields.len]ClientMessageType {
    const request_id: RequestIdType = @enumFromInt(1);
    const pane_id: PaneIdType = @enumFromInt(2);
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(3) };
    const location: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    };
    const size: TerminalSizeType = .{ .cols = 80, .rows = 24 };
    const launch: LaunchViewType = .{
        .cwd = "/work",
        .argument_count = 0,
        .encoded_arguments = "",
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };

    return .{
        .{ .open_pane = .{ .request_id = request_id, .target = .default, .size = size, .launch = null } },
        .{ .pane_input = .{ .pane_id = pane_id, .bytes = "input" } },
        .{ .pane_resize = .{ .pane_id = pane_id, .size = size } },
        .{ .frame_ack = .{ .pane_id = pane_id, .frame_id = 1 } },
        .{ .request_snapshot = .{ .pane_id = pane_id, .known_frame_id = 0 } },
        .{ .detach_pane = .{ .pane_id = pane_id } },
        .{ .runtime_stop = {} },
        .{ .request_tab_snapshot = .{ .request_id = request_id, .location = location } },
        .{ .create_pane = .{ .request_id = request_id, .location = location, .size = size, .launch = launch } },
        .{ .close_pane = .{ .request_id = request_id, .pane_id = pane_id } },
        .{ .query_history = .{ .request_id = request_id } },
        .{ .request_workspace_snapshot = .{ .request_id = request_id, .workspace = workspace } },
        .{ .create_tab = .{ .request_id = request_id, .workspace = workspace, .label = "", .size = size, .launch = launch } },
        .{ .rename_tab = .{ .request_id = request_id, .location = location, .label = "renamed" } },
        .{ .close_tab = .{ .request_id = request_id, .location = location } },
        .{ .move_tab = .{ .request_id = request_id, .location = location, .direction = .next } },
        .{ .request_graphics_snapshot = .{ .pane_id = pane_id } },
        .{ .graphics_credit = .{ .pane_id = pane_id, .bytes = 1 } },
        .{ .configure_graphics = .{ .shared = true } },
        .{ .configure_terminal_colors = .{ .foreground = .{ 255, 255, 255 } } },
        .{ .request_runtime_state = .{ .client_identity = @enumFromInt(5) } },
        .{ .create_workspace = .{ .request_id = request_id, .size = size, .name = "work", .launch = launch } },
        .{ .rename_workspace = .{ .request_id = request_id, .workspace = workspace, .name = "renamed" } },
        .{ .set_pane_viewport = .{ .pane_id = pane_id, .offset = 3 } },
        .{ .copy_selection = .{ .pane_id = pane_id, .start_x = 0, .start_y = 0, .end_x = 1, .end_y = 1 } },
        .{ .show_notification = .{ .request_id = request_id, .notification = .{ .title = "notice" } } },
        .{ .update_client_layout = .{
            .sidebar_visible = true,
            .sidebar_width = 62,
            .workspace_list_collapsed = false,
            .active_tab = location,
            .tab_count = 0,
            .encoded_tabs = "",
        } },
        .{ .acknowledge_agent = .{ .pane_id = pane_id, .pane_generation = 1 } },
        .{ .query_agents = .{ .request_id = request_id } },
        .{ .read_pane = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .rows = 40, .source = .screen } },
        .{ .send_pane_text = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .mode = .prompt, .text = "ls" } },
        .{ .report_agent_session = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .session = "abc" } },
        .{ .report_agent = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .state = .working } },
        .{ .report_agent_command = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .phase = .finished, .provider = "codex", .tool_call_id = "call-1", .command = "zig build test", .cwd = "/work", .exit_code = 0 } },
        .{ .report_agent_title = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .title = "Fix proxy" } },
        .{ .search_pane = .{ .request_id = request_id, .pane_id = pane_id, .needle = "err" } },
        .{ .import_history = .{
            .request_id = request_id,
            .source = "zsh:/tmp/hist",
            .base_sequence = 0,
            .entry_count = 1,
            .encoded_entries = "\xe8\x03\x00\x00\x00\x00\x00\x00\x02\x00ls",
        } },
        .{ .delete_history = .{ .request_id = request_id, .id = 7 } },
        .{ .suggest_command = .{ .request_id = request_id, .pane_id = pane_id, .text = "list files" } },
        .{ .prune_history = .{ .request_id = request_id, .before_ms = 5 } },
        .{ .read_history_output = .{ .request_id = request_id, .id = 4 } },
        .{ .history_stats = .{ .request_id = request_id } },
        .{ .request_pane_focus = .{ .request_id = request_id, .pane_id = pane_id, .pane_generation = 1, .direction = .left } },
        .{ .complete_pane_focus = .{
            .requester = .{ .id = 1, .generation = 1 },
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = 1,
            .outcome = .focused,
            .focused_pane_id = @enumFromInt(3),
        } },
    };
}

test "Router delegates every client tag exactly once and preserves classification" {
    var capture: RequestRouterCapture = .{};
    const router = TestRouter.init(&capture);
    const messages = testingMessages();
    var seen: [messages.len]bool = @splat(false);

    for (messages) |message| {
        const tag = std.meta.activeTag(message);
        const index = @intFromEnum(tag);
        capture.last = null;

        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try router.route(message);

        try std.testing.expectEqual(tag, capture.last.?);
        const expected_class: RequestClass = switch (tag) {
            .runtime_stop,
            .query_history,
            .import_history,
            .delete_history,
            .prune_history,
            .read_history_output,
            .history_stats,
            .show_notification,
            .query_agents,
            .read_pane,
            .send_pane_text,
            .report_agent_session,
            .report_agent,
            .report_agent_command,
            .report_agent_title,
            .request_pane_focus,
            => .control,
            else => .ui,
        };
        try std.testing.expectEqual(expected_class, classify(tag));
    }

    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }

    try std.testing.expectEqual(messages.len, capture.calls);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(2)), capture.pane_input.?.pane_id);
    try std.testing.expectEqualStrings("input", capture.pane_input.?.bytes);
}

test "Router propagates handler failure without a second delegation" {
    var capture: RequestRouterCapture = .{ .failure = .move_tab };
    const router = TestRouter.init(&capture);
    const messages = testingMessages();
    const move_tab = messages[@intFromEnum(Tag.move_tab)];

    try std.testing.expectError(error.RequestHandlerFailed, router.route(move_tab));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(Tag.move_tab, capture.last.?);
}
