//! Exhaustive classification and delegation for decoded client requests.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const Tag = std.meta.Tag(schema.ClientMessage);

pub const RequestClass = enum {
    ui,
    control,
};

pub const Handlers = @import("GenericHandlers.zig").Type;

pub const Router = @import("GenericRouter.zig").Type;

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

const Capture = @import("RequestRouterCapture.zig");

fn captureHandler(comptime tag: Tag, comptime Payload: type) *const fn (*Capture, Payload) anyerror!void {
    return struct {
        fn call(capture: *Capture, payload: Payload) !void {
            capture.calls += 1;
            capture.last = tag;

            if (comptime Payload == schema.PaneInput) {
                capture.pane_input = payload;
            }

            if (capture.failure == tag) {
                return error.RequestHandlerFailed;
            }
        }
    }.call;
}

fn captureVoidHandler(comptime tag: Tag) *const fn (*Capture) anyerror!void {
    return struct {
        fn call(capture: *Capture) !void {
            capture.calls += 1;
            capture.last = tag;

            if (capture.failure == tag) {
                return error.RequestHandlerFailed;
            }
        }
    }.call;
}

const testing_handlers: Handlers(Capture) = .{
    .open_pane = captureHandler(.open_pane, schema.OpenPaneView),
    .pane_input = captureHandler(.pane_input, schema.PaneInput),
    .pane_resize = captureHandler(.pane_resize, schema.PaneResize),
    .frame_ack = captureHandler(.frame_ack, schema.FrameAck),
    .request_snapshot = captureHandler(.request_snapshot, schema.RequestSnapshot),
    .detach_pane = captureHandler(.detach_pane, schema.DetachPane),
    .runtime_stop = captureVoidHandler(.runtime_stop),
    .request_tab_snapshot = captureHandler(.request_tab_snapshot, schema.RequestTabSnapshot),
    .create_pane = captureHandler(.create_pane, schema.CreatePaneView),
    .close_pane = captureHandler(.close_pane, schema.ClosePane),
    .query_history = captureHandler(.query_history, schema.QueryHistory),
    .suggest_command = captureHandler(.suggest_command, schema.SuggestCommand),
    .request_workspace_snapshot = captureHandler(.request_workspace_snapshot, schema.RequestWorkspaceSnapshot),
    .create_tab = captureHandler(.create_tab, schema.CreateTabView),
    .rename_tab = captureHandler(.rename_tab, schema.RenameTab),
    .close_tab = captureHandler(.close_tab, schema.CloseTab),
    .move_tab = captureHandler(.move_tab, schema.MoveTab),
    .request_graphics_snapshot = captureHandler(.request_graphics_snapshot, schema.RequestGraphicsSnapshot),
    .graphics_credit = captureHandler(.graphics_credit, schema.GraphicsCredit),
    .configure_graphics = captureHandler(.configure_graphics, schema.ConfigureGraphics),
    .configure_terminal_colors = captureHandler(.configure_terminal_colors, schema.ConfigureTerminalColors),
    .request_runtime_state = captureHandler(.request_runtime_state, schema.RequestRuntimeState),
    .create_workspace = captureHandler(.create_workspace, schema.CreateWorkspaceView),
    .rename_workspace = captureHandler(.rename_workspace, schema.RenameWorkspace),
    .set_pane_viewport = captureHandler(.set_pane_viewport, schema.SetPaneViewport),
    .copy_selection = captureHandler(.copy_selection, schema.CopySelection),
    .show_notification = captureHandler(.show_notification, schema.ShowNotification),
    .update_client_layout = captureHandler(.update_client_layout, schema.ClientLayoutUpdateView),
    .acknowledge_agent = captureHandler(.acknowledge_agent, schema.AcknowledgeAgent),
    .query_agents = captureHandler(.query_agents, schema.QueryAgents),
    .read_pane = captureHandler(.read_pane, schema.ReadPane),
    .send_pane_text = captureHandler(.send_pane_text, schema.SendPaneText),
    .report_agent_session = captureHandler(.report_agent_session, schema.ReportAgentSession),
    .report_agent = captureHandler(.report_agent, schema.ReportAgent),
    .report_agent_command = captureHandler(.report_agent_command, schema.ReportAgentCommand),
    .report_agent_title = captureHandler(.report_agent_title, schema.ReportAgentTitle),
    .search_pane = captureHandler(.search_pane, schema.SearchPane),
    .import_history = captureHandler(.import_history, schema.ImportHistoryView),
    .delete_history = captureHandler(.delete_history, schema.DeleteHistory),
    .prune_history = captureHandler(.prune_history, schema.PruneHistory),
    .read_history_output = captureHandler(.read_history_output, schema.ReadHistoryOutput),
    .history_stats = captureHandler(.history_stats, schema.HistoryStatsQuery),
    .request_pane_focus = captureHandler(.request_pane_focus, schema.RequestPaneFocus),
    .complete_pane_focus = captureHandler(.complete_pane_focus, schema.CompletePaneFocus),
};

const TestRouter = Router(Capture, testing_handlers);

fn testingMessages() [@typeInfo(Tag).@"enum".fields.len]schema.ClientMessage {
    const request_id: schema.RequestId = @enumFromInt(1);
    const pane_id: schema.PaneId = @enumFromInt(2);
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(3) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    };
    const size: schema.TerminalSize = .{ .cols = 80, .rows = 24 };
    const launch: schema.LaunchView = .{
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
    var capture: Capture = .{};
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
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), capture.pane_input.?.pane_id);
    try std.testing.expectEqualStrings("input", capture.pane_input.?.bytes);
}

test "Router propagates handler failure without a second delegation" {
    var capture: Capture = .{ .failure = .move_tab };
    const router = TestRouter.init(&capture);
    const messages = testingMessages();
    const move_tab = messages[@intFromEnum(Tag.move_tab)];

    try std.testing.expectError(error.RequestHandlerFailed, router.route(move_tab));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(Tag.move_tab, capture.last.?);
}
