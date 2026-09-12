//! Wire-level tests for the protocol schema.
//!
//! The golden corpus below pins the exact bytes of one representative message
//! per tag in both directions. Any change to an encoding fails these tests,
//! and the handshake fingerprint is derived from the same corpus, so a wire
//! change cannot ship without a visible schema bump.

const std = @import("std");
const schema = @import("schema/schema.zig");
const Entry = @import("Entry.zig");
const TabLocationType = @import("schema/TabLocation.zig");
const EnvironmentEntryType = @import("schema/EnvironmentEntry.zig");
const types = @import("schema/types.zig");
const ClientTabLayoutType = @import("schema/ClientTabLayout.zig");
const EntryMetadata = @import("EntryMetadata.zig");
const golden = @import("golden.zig");
const pane_module = @import("schema/messages/pane.zig");
const workspace_module = @import("schema/messages/workspace.zig");
const runtime = @import("schema/messages/runtime.zig");
const tab_module = @import("schema/messages/tab.zig");
const history = @import("schema/messages/history.zig");
const ImportEntryType = @import("schema/messages/ImportEntry.zig");
const graphics = @import("schema/messages/graphics.zig");
const notification_support = @import("schema/messages/notification_support.zig");
const layout = @import("schema/messages/layout.zig");
const agent_module = @import("schema/messages/agent.zig");
const focus = @import("schema/messages/focus.zig");
const CellType = @import("ui/Cell.zig");
const SpanType = @import("schema/Span.zig");
const PaneDescriptorType = @import("schema/PaneDescriptor.zig");
const HistoryEntryType = @import("schema/HistoryEntry.zig");
const HistoryStatsTopType = @import("schema/messages/HistoryStatsTop.zig");
const suggestion = @import("schema/messages/suggestion.zig");
const TabDescriptorType = @import("schema/TabDescriptor.zig");
const ShmNameType = @import("ShmName.zig");
const AgentSnapshotEntryType = @import("schema/AgentSnapshotEntry.zig");
const WorkspaceListEntryType = @import("schema/messages/WorkspaceListEntry.zig");
const root = @import("schema/messages/messages.zig");
const TerminalColorsType = @import("schema/TerminalColors.zig");
const PlacementType = @import("schema/Placement.zig");
const id_module = @import("schema/id.zig");
const TerminalSizeType = @import("schema/TerminalSize.zig");
const FrameViewType = @import("schema/FrameView.zig");
const LaunchViewType = @import("schema/messages/LaunchView.zig");
const frame = @import("schema/frame_support.zig");
const handshake = @import("schema/handshake.zig");
const OpenPaneType = @import("schema/messages/OpenPane.zig");
const FrameType = @import("schema/Frame.zig");
const tags = @import("schema/messages/tags.zig");

test {
    std.testing.refAllDecls(schema);
}

pub const Direction = enum { client, server };

const corpus_len = 90;
const corpus_storage_size = 8 * 1024;

fn buildCorpus(storage: []u8) ![corpus_len]Entry {
    var entries: [corpus_len]Entry = undefined;
    var used: usize = 0;
    var index: usize = 0;

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };

    const arguments = [_][]const u8{ "/bin/sh", "-l" };
    const environment = [_]EnvironmentEntryType{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "EMPTY", .value = "" },
    };
    const client_layout_nodes = [_]types.ClientLayoutNode{
        .{ .split = .{ .axis = .horizontal, .ratio = 6000 } },
        .{ .pane = .{ .id = @enumFromInt(5) } },
        .{ .pane = .{ .id = @enumFromInt(6), .surface = .thread } },
    };
    const client_layout_tabs = [_]ClientTabLayoutType{.{
        .location = location,
        .focused_pane = @enumFromInt(5),
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &client_layout_nodes,
    }};

    const helper = struct {
        entries: *[corpus_len]Entry,
        storage: []u8,
        used: *usize,
        index: *usize,

        fn add(h: @This(), metadata: EntryMetadata, payload: []const u8) void {
            h.entries[h.index.*] = .{
                .name = metadata.name,
                .direction = metadata.direction,
                .bytes = payload,
                .golden_hex = metadata.golden_hex,
            };
            h.index.* += 1;
        }

        fn addTailTolerant(h: @This(), metadata: EntryMetadata, payload: []const u8) void {
            h.add(metadata, payload);
            h.entries[h.index.* - 1].tail_tolerant = true;
        }

        fn space(h: @This()) []u8 {
            return h.storage[h.used.*..];
        }

        fn commit(h: @This(), payload: []const u8) []const u8 {
            h.used.* += payload.len;
            return payload;
        }
    }{ .entries = &entries, .storage = storage, .used = &used, .index = &index };

    // -- client ------------------------------------------------------------
    helper.add(.{ .name = "open_pane_default", .direction = .client, .golden_hex = golden.open_pane_default }, helper.commit(
        try pane_module.encodeOpenPane(helper.space(), .{
            .request_id = @enumFromInt(9),
            .size = .{ .cols = 120, .rows = 40, .cell_width_px = 8, .cell_height_px = 16 },
            .launch = .{
                .cwd = "/work",
                .arguments = &arguments,
                .environment_mode = .replace,
                .environment = &environment,
            },
        }),
    ));
    helper.add(.{ .name = "open_pane_attach", .direction = .client, .golden_hex = golden.open_pane_attach }, helper.commit(
        try pane_module.encodeOpenPane(helper.space(), .{
            .request_id = @enumFromInt(2),
            .target = .{ .pane = @enumFromInt(41) },
            .size = .{ .cols = 80, .rows = 24 },
            .launch = null,
        }),
    ));
    helper.add(.{ .name = "open_workspace", .direction = .client, .golden_hex = golden.open_workspace }, helper.commit(
        try pane_module.encodeOpenPane(helper.space(), .{
            .request_id = @enumFromInt(3),
            .target = .{ .workspace = @enumFromInt(7) },
            .size = .{ .cols = 80, .rows = 24 },
            .launch = null,
        }),
    ));
    helper.add(.{ .name = "create_workspace", .direction = .client, .golden_hex = golden.create_workspace }, helper.commit(
        try workspace_module.encodeCreateWorkspace(helper.space(), .{
            .request_id = @enumFromInt(4),
            .size = .{ .cols = 80, .rows = 24 },
            .name = "agents",
            .launch = .{
                .cwd = "/work",
                .cwd_source = @enumFromInt(5),
                .arguments = &arguments,
                .environment_mode = .replace,
                .environment = &environment,
            },
        }),
    ));
    helper.add(.{ .name = "rename_workspace", .direction = .client, .golden_hex = golden.rename_workspace }, helper.commit(
        try workspace_module.encodeRenameWorkspace(helper.space(), .{
            .request_id = @enumFromInt(5),
            .workspace = .{ .workspace = @enumFromInt(7) },
            .name = "agents",
        }),
    ));
    helper.addTailTolerant(.{ .name = "pane_input", .direction = .client, .golden_hex = golden.pane_input }, helper.commit(
        try pane_module.encodePaneInput(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .bytes = "abc",
        }),
    ));
    helper.add(.{ .name = "pane_resize", .direction = .client, .golden_hex = golden.pane_resize }, helper.commit(
        try pane_module.encodePaneResize(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .size = .{ .cols = 90, .rows = 30 },
        }),
    ));
    helper.add(.{ .name = "frame_ack", .direction = .client, .golden_hex = golden.frame_ack }, helper.commit(
        try pane_module.encodeFrameAck(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .frame_id = 8,
        }),
    ));
    helper.add(.{ .name = "request_snapshot", .direction = .client, .golden_hex = golden.request_snapshot }, helper.commit(
        try pane_module.encodeRequestSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .known_frame_id = 7,
        }),
    ));
    helper.add(.{ .name = "detach_pane", .direction = .client, .golden_hex = golden.detach_pane }, helper.commit(
        try pane_module.encodeDetachPane(helper.space(), .{ .pane_id = @enumFromInt(3) }),
    ));
    helper.add(.{ .name = "runtime_stop", .direction = .client, .golden_hex = golden.runtime_stop }, helper.commit(
        try runtime.encodeRuntimeStop(helper.space()),
    ));
    helper.add(.{ .name = "request_tab_snapshot", .direction = .client, .golden_hex = golden.request_tab_snapshot }, helper.commit(
        try tab_module.encodeRequestTabSnapshot(helper.space(), .{
            .request_id = @enumFromInt(20),
            .location = location,
        }),
    ));
    helper.add(.{ .name = "create_pane", .direction = .client, .golden_hex = golden.create_pane }, helper.commit(
        try pane_module.encodeCreatePane(helper.space(), .{
            .request_id = @enumFromInt(21),
            .location = location,
            .size = .{ .cols = 60, .rows = 20 },
            .launch = .{
                .cwd = "/work",
                .cwd_source = @enumFromInt(6),
                .arguments = &.{"/bin/sh"},
            },
        }),
    ));
    helper.add(.{ .name = "close_pane", .direction = .client, .golden_hex = golden.close_pane }, helper.commit(
        try pane_module.encodeClosePane(helper.space(), .{
            .request_id = @enumFromInt(22),
            .pane_id = @enumFromInt(8),
        }),
    ));
    helper.add(.{ .name = "query_history_cwd", .direction = .client, .golden_hex = golden.query_history_cwd }, helper.commit(
        try history.encodeQueryHistory(helper.space(), .{
            .request_id = @enumFromInt(31),
            .query = "zig build",
            .scope = .cwd,
            .scope_value = "/work/telar",
            .failed_only = true,
            .match = .fuzzy,
            .distinct = true,
            .limit = 12,
        }),
    ));
    const import_entries = [_]ImportEntryType{
        .{ .started_at_ms = 1700000002000, .command = "git status" },
        .{ .started_at_ms = 1700000003000, .command = "make -j4" },
    };
    helper.add(.{ .name = "import_history", .direction = .client, .golden_hex = golden.import_history }, helper.commit(
        try history.encodeImportHistory(helper.space(), .{
            .request_id = @enumFromInt(34),
            .source = "zsh:/home/u/.zsh_history",
            .base_sequence = 100,
            .entries = &import_entries,
        }),
    ));
    helper.add(.{ .name = "delete_history", .direction = .client, .golden_hex = golden.delete_history }, helper.commit(
        try history.encodeDeleteHistory(helper.space(), .{
            .request_id = @enumFromInt(35),
            .id = 11,
        }),
    ));
    helper.add(.{ .name = "prune_history", .direction = .client, .golden_hex = golden.prune_history }, helper.commit(
        try history.encodePruneHistory(helper.space(), .{
            .request_id = @enumFromInt(36),
            .scope = .workspace,
            .scope_value = "/work/telar",
            .before_ms = 1700000000000,
            .failed_only = true,
            .match = "zig",
        }),
    ));
    helper.add(.{ .name = "read_history_output", .direction = .client, .golden_hex = golden.read_history_output }, helper.commit(
        try history.encodeReadHistoryOutput(helper.space(), .{
            .request_id = @enumFromInt(37),
            .id = 11,
        }),
    ));
    helper.add(.{ .name = "history_stats", .direction = .client, .golden_hex = golden.history_stats }, helper.commit(
        try history.encodeHistoryStatsQuery(helper.space(), .{
            .request_id = @enumFromInt(38),
            .scope = .workspace,
            .scope_value = "/work/telar",
            .since_ms = 1700000000000,
        }),
    ));
    helper.add(.{ .name = "query_history_pane", .direction = .client, .golden_hex = golden.query_history_pane }, helper.commit(
        try history.encodeQueryHistory(helper.space(), .{
            .request_id = @enumFromInt(32),
            .scope = .pane,
            .pane_id = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "request_workspace_snapshot", .direction = .client, .golden_hex = golden.request_workspace_snapshot }, helper.commit(
        try workspace_module.encodeRequestWorkspaceSnapshot(helper.space(), .{
            .request_id = @enumFromInt(40),
            .workspace = .{ .workspace = @enumFromInt(7) },
        }),
    ));
    helper.add(.{ .name = "create_tab", .direction = .client, .golden_hex = golden.create_tab }, helper.commit(
        try tab_module.encodeCreateTab(helper.space(), .{
            .request_id = @enumFromInt(41),
            .workspace = .{ .workspace = @enumFromInt(7) },
            .label = "logs",
            .size = .{ .cols = 80, .rows = 24 },
            .launch = .{
                .cwd = "/work",
                .cwd_source = @enumFromInt(7),
                .arguments = &.{"/bin/sh"},
            },
        }),
    ));
    helper.add(.{ .name = "rename_tab", .direction = .client, .golden_hex = golden.rename_tab }, helper.commit(
        try tab_module.encodeRenameTab(helper.space(), .{
            .request_id = @enumFromInt(42),
            .location = location,
            .label = "server",
        }),
    ));
    helper.add(.{ .name = "close_tab", .direction = .client, .golden_hex = golden.close_tab }, helper.commit(
        try tab_module.encodeCloseTab(helper.space(), .{
            .request_id = @enumFromInt(43),
            .location = location,
        }),
    ));
    helper.add(.{ .name = "move_tab", .direction = .client, .golden_hex = golden.move_tab }, helper.commit(
        try tab_module.encodeMoveTab(helper.space(), .{
            .request_id = @enumFromInt(44),
            .location = location,
            .direction = .previous,
        }),
    ));
    helper.add(.{ .name = "request_graphics_snapshot", .direction = .client, .golden_hex = golden.request_graphics_snapshot }, helper.commit(
        try graphics.encodeRequestGraphicsSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(5),
        }),
    ));
    helper.add(.{ .name = "graphics_credit", .direction = .client, .golden_hex = golden.graphics_credit }, helper.commit(
        try graphics.encodeGraphicsCredit(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .bytes = 4096,
        }),
    ));
    helper.add(.{ .name = "configure_graphics", .direction = .client, .golden_hex = golden.configure_graphics }, helper.commit(
        try graphics.encodeConfigureGraphics(helper.space(), .{
            .shared = true,
        }),
    ));
    helper.add(.{ .name = "configure_terminal_colors", .direction = .client, .golden_hex = golden.configure_terminal_colors }, helper.commit(
        try runtime.encodeConfigureTerminalColors(helper.space(), .{
            .foreground = .{ 255, 255, 255 },
            .background = .{ 16, 16, 16 },
        }),
    ));
    helper.add(.{ .name = "request_runtime_state", .direction = .client, .golden_hex = golden.request_runtime_state }, helper.commit(
        try runtime.encodeRequestRuntimeState(helper.space(), .{
            .client_identity = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "set_pane_viewport", .direction = .client, .golden_hex = golden.set_pane_viewport }, helper.commit(
        try pane_module.encodeSetPaneViewport(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .offset = 42,
        }),
    ));
    helper.add(.{ .name = "copy_selection", .direction = .client, .golden_hex = golden.copy_selection }, helper.commit(
        try pane_module.encodeCopySelection(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .start_x = 1,
            .start_y = 2,
            .end_x = 3,
            .end_y = 4,
            .linewise = true,
        }),
    ));
    helper.add(.{ .name = "show_notification", .direction = .client, .golden_hex = golden.show_notification }, helper.commit(
        try notification_support.encodeShowNotification(helper.space(), .{
            .request_id = @enumFromInt(45),
            .notification = .{
                .level = .success,
                .duration_ms = 2500,
                .target = .{ .pane = @enumFromInt(5) },
                .title = "Build complete",
                .message = "Open the pane",
            },
        }),
    ));
    helper.add(.{ .name = "update_client_layout", .direction = .client, .golden_hex = golden.update_client_layout }, helper.commit(
        try layout.encodeClientLayoutUpdate(helper.space(), .{
            .sidebar_visible = true,
            .sidebar_width = 73,
            .workspace_list_collapsed = true,
            .active_tab = location,
            .tabs = &client_layout_tabs,
        }),
    ));
    helper.add(.{ .name = "acknowledge_agent", .direction = .client, .golden_hex = golden.acknowledge_agent }, helper.commit(
        try agent_module.encodeAcknowledgeAgent(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
        }),
    ));
    helper.add(.{ .name = "query_agents", .direction = .client, .golden_hex = golden.query_agents }, helper.commit(
        try agent_module.encodeQueryAgents(helper.space(), .{ .request_id = @enumFromInt(5) }),
    ));
    helper.add(.{ .name = "read_pane", .direction = .client, .golden_hex = golden.read_pane }, helper.commit(
        try pane_module.encodeReadPane(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .rows = 40,
            .source = .recent,
        }),
    ));
    helper.add(.{ .name = "send_pane_text", .direction = .client, .golden_hex = golden.send_pane_text }, helper.commit(
        try pane_module.encodeSendPaneText(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .mode = .prompt,
            .text = "ls",
        }),
    ));
    helper.add(.{ .name = "report_agent_session", .direction = .client, .golden_hex = golden.report_agent_session }, helper.commit(
        try agent_module.encodeReportAgentSession(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .session = "abc",
        }),
    ));
    helper.add(.{ .name = "report_agent", .direction = .client, .golden_hex = golden.report_agent }, helper.commit(
        try agent_module.encodeReportAgent(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .state = .blocked,
            .session = "abc",
        }),
    ));
    helper.add(.{ .name = "report_agent_settling", .direction = .client, .golden_hex = golden.report_agent_settling }, helper.commit(
        try agent_module.encodeReportAgent(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .state = .settling,
            .session = "abc",
        }),
    ));
    helper.add(.{ .name = "report_agent_command", .direction = .client, .golden_hex = golden.report_agent_command }, helper.commit(
        try agent_module.encodeReportAgentCommand(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .phase = .finished,
            .provider = "codex",
            .tool_call_id = "call-7",
            .command = "zig build test",
            .cwd = "/work",
            .session = "abc",
            .exit_code = 7,
        }),
    ));
    helper.add(.{ .name = "report_agent_title", .direction = .client, .golden_hex = golden.report_agent_title }, helper.commit(
        try agent_module.encodeReportAgentTitle(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .title = "Fix proxy",
        }),
    ));
    helper.add(.{ .name = "search_pane", .direction = .client, .golden_hex = golden.search_pane }, helper.commit(
        try pane_module.encodeSearchPane(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .needle = "err",
        }),
    ));
    helper.add(.{ .name = "request_pane_focus", .direction = .client, .golden_hex = golden.request_pane_focus }, helper.commit(
        try focus.encodeRequestPaneFocus(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .direction = .left,
        }),
    ));
    helper.add(.{ .name = "complete_pane_focus", .direction = .client, .golden_hex = golden.complete_pane_focus }, helper.commit(
        try focus.encodeCompletePaneFocus(helper.space(), .{
            .requester = .{ .id = 9, .generation = 10 },
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .outcome = .focused,
            .focused_pane_id = @enumFromInt(6),
        }),
    ));

    // -- server ------------------------------------------------------------
    helper.add(.{ .name = "pane_opened", .direction = .server, .golden_hex = golden.pane_opened }, helper.commit(
        try pane_module.encodePaneOpened(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(12),
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(4),
            },
            .created = true,
        }),
    ));
    const frame_cells = [_]CellType{
        .{},
        .{
            .bytes = [_]u8{'x'} ++ [_]u8{0} ** (CellType.max_bytes - 1),
            .len = 1,
            .width = 1,
            .style = .{
                .fg = .{ .rgb = .{ 1, 2, 3 } },
                .bg = .{ .indexed = 4 },
                .flags = .{ .bold = true, .underline = .curly },
            },
        },
    };
    const frame_spans = [_]SpanType{.{ .start = 0, .cells = &frame_cells }};
    helper.add(.{ .name = "pane_frame", .direction = .server, .golden_hex = golden.pane_frame }, helper.commit(
        try pane_module.encodePaneFrame(helper.space(), .{
            .pane_id = @enumFromInt(4),
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 2,
            .rows = 1,
            .cursor = .{ .visible = true, .x = 1, .y = 0 },
            .input_modes = .{
                .focus_events = true,
                .kitty_keyboard_flags = 5,
                .modify_other_keys_2 = true,
            },
            .pointer_shape = .pointer,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &frame_spans,
        }),
    ));
    helper.add(.{ .name = "pane_exited", .direction = .server, .golden_hex = golden.pane_exited }, helper.commit(
        try pane_module.encodePaneExited(helper.space(), .{
            .pane_id = @enumFromInt(12),
            .kind = .exited,
            .value = 7,
        }),
    ));
    helper.addTailTolerant(.{ .name = "request_failed", .direction = .server, .golden_hex = golden.request_failed }, helper.commit(
        try runtime.encodeRequestFailed(helper.space(), .{
            .request_id = @enumFromInt(5),
            .code = .pane_not_found,
            .message = "pane 12 does not exist",
        }),
    ));
    helper.add(.{ .name = "runtime_stopping", .direction = .server, .golden_hex = golden.runtime_stopping }, helper.commit(
        try runtime.encodeRuntimeStopping(helper.space()),
    ));
    const panes = [_]PaneDescriptorType{
        .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        .{ .pane_id = @enumFromInt(9), .lifecycle = .exited },
    };
    helper.add(.{ .name = "tab_snapshot", .direction = .server, .golden_hex = golden.tab_snapshot }, helper.commit(
        try tab_module.encodeTabSnapshot(helper.space(), .{
            .request_id = @enumFromInt(4),
            .location = .{
                .workspace = .{ .worktree = @enumFromInt(2) },
                .tab_id = @enumFromInt(6),
            },
            .panes = &panes,
        }),
    ));
    const history_entries = [_]HistoryEntryType{
        .{
            .id = 11,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000000000,
            .duration_ns = 42_000,
            .exit_code = 7,
            .status = .completed,
            .command = "zig build test",
            .cwd = "/work/telar",
            .workspace_path = "/work/telar",
        },
        .{
            .id = 12,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000001000,
            .duration_ns = 9,
            .exit_code = null,
            .status = .interrupted,
            .author = .agent,
            .command = "sleep 600",
            .cwd = "/work/telar",
            .workspace_path = "/work/telar",
        },
    };
    helper.add(.{ .name = "history_output", .direction = .server, .golden_hex = golden.history_output }, helper.commit(
        try history.encodeHistoryOutput(helper.space(), .{
            .request_id = @enumFromInt(37),
            .id = 11,
            .truncated = true,
            .observed_bytes = 9000,
            .content = "error: exit 1\n",
        }),
    ));
    const stats_top = [_]HistoryStatsTopType{
        .{ .count = 30, .command = "git status" },
        .{ .count = 12, .command = "zig build" },
    };
    helper.add(.{ .name = "history_stats_result", .direction = .server, .golden_hex = golden.history_stats_result }, helper.commit(
        try history.encodeHistoryStats(helper.space(), .{
            .request_id = @enumFromInt(38),
            .total = 120,
            .unique = 40,
            .top = &stats_top,
        }),
    ));
    helper.add(.{ .name = "history_pruned", .direction = .server, .golden_hex = golden.history_pruned }, helper.commit(
        try history.encodeHistoryPruned(helper.space(), .{
            .request_id = @enumFromInt(36),
            .removed = 3,
        }),
    ));
    helper.add(.{ .name = "history_results", .direction = .server, .golden_hex = golden.history_results }, helper.commit(
        try history.encodeHistoryResults(helper.space(), .{
            .request_id = @enumFromInt(33),
            .entries = &history_entries,
        }),
    ));
    helper.add(.{ .name = "suggest_command", .direction = .client, .golden_hex = golden.suggest_command }, helper.commit(
        try suggestion.encodeSuggestCommand(helper.space(), .{
            .request_id = @enumFromInt(41),
            .pane_id = @enumFromInt(9),
            .text = "list files by size",
        }),
    ));
    helper.add(.{ .name = "command_suggestion", .direction = .server, .golden_hex = golden.command_suggestion }, helper.commit(
        try suggestion.encodeCommandSuggestion(helper.space(), .{
            .request_id = @enumFromInt(41),
            .status = .ready,
            .text = "ls -lS",
        }),
    ));
    const descriptors = [_]TabDescriptorType{
        .{ .tab_id = @enumFromInt(3), .position = 0, .pane_count = 2, .label = "main" },
        .{ .tab_id = @enumFromInt(4), .position = 1, .pane_count = 1, .label = "logs" },
    };
    helper.add(.{ .name = "workspace_snapshot", .direction = .server, .golden_hex = golden.workspace_snapshot }, helper.commit(
        try workspace_module.encodeWorkspaceSnapshot(helper.space(), .{
            .request_id = @enumFromInt(50),
            .workspace = .{ .workspace = @enumFromInt(7) },
            .name = "telar",
            .tabs = &descriptors,
        }),
    ));
    helper.add(.{ .name = "tab_created", .direction = .server, .golden_hex = golden.tab_created }, helper.commit(
        try tab_module.encodeTabCreated(helper.space(), .{
            .request_id = @enumFromInt(51),
            .location = location,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "tab_renamed", .direction = .server, .golden_hex = golden.tab_renamed }, helper.commit(
        try tab_module.encodeTabRenamed(helper.space(), .{
            .request_id = @enumFromInt(52),
            .location = location,
            .label = "server",
        }),
    ));
    helper.add(.{ .name = "tab_closed", .direction = .server, .golden_hex = golden.tab_closed }, helper.commit(
        try tab_module.encodeTabClosed(helper.space(), .{
            .request_id = .none,
            .location = location,
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(6),
        }),
    ));
    helper.add(.{ .name = "tab_moved", .direction = .server, .golden_hex = golden.tab_moved }, helper.commit(
        try tab_module.encodeTabMoved(helper.space(), .{
            .request_id = @enumFromInt(54),
            .location = location,
            .position = 0,
        }),
    ));
    helper.add(.{ .name = "resync_required", .direction = .server, .golden_hex = golden.resync_required }, helper.commit(
        try workspace_module.encodeResyncRequired(helper.space(), .{
            .workspace = .{ .workspace = @enumFromInt(7) },
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(6),
        }),
    ));
    helper.add(.{ .name = "graphics_snapshot", .direction = .server, .golden_hex = golden.graphics_snapshot }, helper.commit(
        try graphics.encodeGraphicsSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .phase = .begin,
        }),
    ));
    helper.add(.{ .name = "graphics_image", .direction = .server, .golden_hex = golden.graphics_image }, helper.commit(
        try graphics.encodeGraphicsImage(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .image = .{
                .key = .{ .image_id = 7, .generation = 8 },
                .format = .rgba,
                .width = 2,
                .height = 2,
                .byte_len = 16,
            },
        }),
    ));
    helper.add(.{ .name = "graphics_image_chunk", .direction = .server, .golden_hex = golden.graphics_image_chunk }, helper.commit(
        try graphics.encodeGraphicsImageChunk(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .key = .{ .image_id = 7, .generation = 8 },
            .offset = 0,
            .bytes = &.{ 1, 2, 3, 4 },
        }),
    ));
    helper.add(.{ .name = "graphics_shared_image", .direction = .server, .golden_hex = golden.graphics_shared_image }, helper.commit(
        try graphics.encodeGraphicsSharedImage(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .image = .{
                .key = .{ .image_id = 7, .generation = 8 },
                .format = .rgba,
                .width = 2,
                .height = 2,
                .byte_len = 16,
            },
            .name = try ShmNameType.init("/tlr0000002a-7"),
        }),
    ));
    helper.add(.{ .name = "graphics_placement", .direction = .server, .golden_hex = golden.graphics_placement }, helper.commit(
        try graphics.encodeGraphicsPlacement(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .placement = .{
                .key = .{ .image_id = 7, .generation = 8 },
                .virtual_id = 1,
                .placement_id = 1,
                .x = 2,
                .y = 3,
                .source_width = 2,
                .source_height = 2,
                .columns = 1,
                .rows = 1,
            },
        }),
    ));
    helper.add(.{ .name = "graphics_delete_image", .direction = .server, .golden_hex = golden.graphics_delete_image }, helper.commit(
        try graphics.encodeGraphicsDeleteImage(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 4,
            .key = .{ .image_id = 7, .generation = 8 },
        }),
    ));
    helper.add(.{ .name = "graphics_delete_placement", .direction = .server, .golden_hex = golden.graphics_delete_placement }, helper.commit(
        try graphics.encodeGraphicsDeletePlacement(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 5,
            .key = .{ .image_id = 7, .generation = 8 },
            .virtual_id = 1,
            .placement_id = 1,
        }),
    ));
    helper.add(.{ .name = "proxy_status", .direction = .server, .golden_hex = golden.proxy_status }, helper.commit(
        try runtime.encodeProxyStatus(helper.space(), .{ .active = true, .scope = .wildcard, .system_trusted = true }),
    ));
    const agent_entries = [_]AgentSnapshotEntryType{.{
        .pane_id = @enumFromInt(5),
        .pane_generation = 7,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(4),
        },
        .pane_index = 3,
        .process_id = 42,
        .session_id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .workspace_label = "telar",
        .tab_label = "test-2",
        .session_title = "Improve agent context",
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .provider_name = "codex",
        .display_name = "Codex",
        .icon = "X",
        .attachments = .ordered,
        .status = .working,
        .source = .foreground_process,
        .authority = .active,
        .confidence = 95,
        .sequence = 11,
        .observed_at_ms = 1000,
        .expires_at_ms = 2000,
    }};
    helper.add(.{ .name = "agent_snapshot", .direction = .server, .golden_hex = golden.agent_snapshot }, helper.commit(
        try agent_module.encodeAgentSnapshot(helper.space(), .{
            .revision = 9,
            .entries = &agent_entries,
        }),
    ));
    helper.add(.{ .name = "system_metrics", .direction = .server, .golden_hex = golden.system_metrics }, helper.commit(
        try runtime.encodeSystemMetrics(helper.space(), .{
            .revision = 5,
            .cpu_percent = 42,
            .memory_used_decigib = 92,
            .has_battery = true,
            .battery_percent = 84,
        }),
    ));
    const workspace_list_entries = [_]WorkspaceListEntryType{
        .{
            .workspace = @enumFromInt(7),
            .name = "telar",
            .path = "/work/telar",
            .tab_count = 2,
            .branch = "main",
            .dirty = true,
        },
        .{
            .workspace = @enumFromInt(9),
            .name = "api",
            .path = "/work/api",
            .tab_count = 1,
        },
    };
    helper.add(.{ .name = "workspace_list", .direction = .server, .golden_hex = golden.workspace_list }, helper.commit(
        try workspace_module.encodeWorkspaceList(helper.space(), .{
            .revision = 3,
            .entries = &workspace_list_entries,
        }),
    ));
    helper.add(.{ .name = "pane_cwd", .direction = .server, .golden_hex = golden.pane_cwd }, helper.commit(
        try pane_module.encodePaneCwd(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .cwd = "/work/telar",
        }),
    ));
    helper.add(.{ .name = "pane_foreground", .direction = .server, .golden_hex = golden.pane_foreground }, helper.commit(
        try pane_module.encodePaneForeground(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .name = "zsh",
        }),
    ));
    helper.add(.{ .name = "pane_clipboard", .direction = .server, .golden_hex = golden.pane_clipboard }, helper.commit(
        try pane_module.encodePaneClipboard(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .bytes = "abc",
        }),
    ));
    helper.add(.{ .name = "notification", .direction = .server, .golden_hex = golden.notification }, helper.commit(
        try notification_support.encodeNotification(helper.space(), .{
            .level = .warning,
            .duration_ms = 3000,
            .target = .{ .tab = @enumFromInt(3) },
            .title = "Agent waiting",
            .message = "Review its question",
        }),
    ));
    helper.add(.{ .name = "notification_shown", .direction = .server, .golden_hex = golden.notification_shown }, helper.commit(
        try notification_support.encodeNotificationShown(helper.space(), .{
            .request_id = @enumFromInt(46),
            .delivered_clients = 2,
        }),
    ));
    helper.add(.{ .name = "agent_sound", .direction = .server, .golden_hex = golden.agent_sound }, helper.commit(
        try agent_module.encodeAgentSound(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .pane_generation = 7,
            .sound = .needs_input,
        }),
    ));
    helper.add(.{ .name = "client_layout_snapshot", .direction = .server, .golden_hex = golden.client_layout_snapshot }, helper.commit(
        try layout.encodeClientLayoutSnapshot(helper.space(), .{
            .restored = true,
            .sidebar_visible = true,
            .sidebar_width = 73,
            .workspace_list_collapsed = true,
            .active_tab = location,
            .tabs = &client_layout_tabs,
        }),
    ));
    helper.add(.{ .name = "pane_text", .direction = .server, .golden_hex = golden.pane_text }, helper.commit(
        try pane_module.encodePaneText(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .truncated = false,
            .text = "hi",
        }),
    ));
    helper.add(.{ .name = "request_completed", .direction = .server, .golden_hex = golden.request_completed }, helper.commit(
        try runtime.encodeRequestCompleted(helper.space(), .{ .request_id = @enumFromInt(5) }),
    ));
    helper.add(.{ .name = "pane_title", .direction = .server, .golden_hex = golden.pane_title }, helper.commit(
        try pane_module.encodePaneTitle(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .title = "vim",
        }),
    ));
    helper.add(.{ .name = "pane_progress", .direction = .server, .golden_hex = golden.pane_progress }, helper.commit(
        try pane_module.encodePaneProgress(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .state = .set,
            .percent = 42,
        }),
    ));
    helper.add(.{ .name = "pane_matches", .direction = .server, .golden_hex = golden.pane_matches }, helper.commit(
        try pane_module.encodePaneMatches(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .truncated = false,
            .matches = &.{.{ .x = 2, .y = 7, .len = 3 }},
        }),
    ));
    helper.add(.{ .name = "pane_focus_command", .direction = .server, .golden_hex = golden.pane_focus_command }, helper.commit(
        try focus.encodePaneFocusCommand(helper.space(), .{
            .requester = .{ .id = 9, .generation = 10 },
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .direction = .left,
        }),
    ));
    helper.add(.{ .name = "pane_focus_result", .direction = .server, .golden_hex = golden.pane_focus_result }, helper.commit(
        try focus.encodePaneFocusResult(helper.space(), .{
            .request_id = @enumFromInt(5),
            .outcome = .focused,
            .focused_pane_id = @enumFromInt(6),
        }),
    ));

    std.debug.assert(index == corpus_len);
    return entries;
}

fn fingerprint(entries: []const Entry) [6]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |entry| {
        hasher.update(entry.name);
        hasher.update(&.{0});
        hasher.update(entry.bytes);
        hasher.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>6}", .{
        std.mem.readInt(u24, digest[0..3], .big),
    }) catch unreachable;
    return hex;
}

fn decodeEntry(entry: Entry, payload: []const u8) !void {
    switch (entry.direction) {
        .client => _ = try root.decodeClient(payload),
        .server => _ = try root.decodeServer(payload),
    }
}

test "terminal color configuration preserves partial unknowns and rejects malformed flags" {
    var buffer: [16]u8 = undefined;
    for ([_]?[3]u8{ null, .{ 1, 2, 3 } }) |foreground| {
        for ([_]?[3]u8{ null, .{ 4, 5, 6 } }) |background| {
            const colors: TerminalColorsType = .{ .foreground = foreground, .background = background };
            const encoded = try runtime.encodeConfigureTerminalColors(&buffer, colors);
            const decoded = try root.decodeClient(encoded);
            try std.testing.expectEqualDeep(colors, decoded.configure_terminal_colors);
        }
    }

    try std.testing.expectError(error.InvalidBoolean, root.decodeClient(&.{ 0x2c, 2, 0 }));
}

test "golden corpus bytes are stable" {
    var storage: [corpus_storage_size]u8 = undefined;
    const entries = try buildCorpus(&storage);
    var expected: [corpus_storage_size]u8 = undefined;
    for (entries) |entry| {
        const bytes = std.fmt.hexToBytes(&expected, entry.golden_hex) catch |err| {
            std.debug.print("bad golden hex for {s}\n", .{entry.name});
            return err;
        };
        std.testing.expectEqualSlices(u8, bytes, entry.bytes) catch |err| {
            std.debug.print(
                "encoding drifted for {s}; expected {s}, got {x}\n",
                .{ entry.name, entry.golden_hex, entry.bytes },
            );
            return err;
        };
    }
}

test "every corpus message decodes" {
    var storage: [corpus_storage_size]u8 = undefined;
    const entries = try buildCorpus(&storage);
    for (entries) |entry| try decodeEntry(entry, entry.bytes);
}

test "every truncated prefix of every message is rejected" {
    var storage: [corpus_storage_size]u8 = undefined;
    const entries = try buildCorpus(&storage);
    for (entries) |entry| {
        for (0..entry.bytes.len) |length| {
            if (decodeEntry(entry, entry.bytes[0..length])) |_| {
                // Only messages whose payload ends in raw unprefixed bytes may
                // decode a prefix as a valid shorter message.
                std.testing.expect(entry.tail_tolerant) catch |err| {
                    std.debug.print(
                        "prefix {d} of {s} decoded successfully\n",
                        .{ length, entry.name },
                    );
                    return err;
                };
            } else |_| {}
        }
    }
}

test "a workspace snapshot with zero tabs round trips" {
    // The runtime can transiently hold a workspace with no tabs; the decoder
    // must accept what the encoder produces.
    var buffer: [64]u8 = undefined;
    const decoded = (try root.decodeServer(try workspace_module.encodeWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(60),
        .workspace = .{ .workspace = @enumFromInt(7) },
        .name = "telar",
        .tabs = &.{},
    }))).workspace_snapshot;
    try std.testing.expectEqualStrings("telar", decoded.name);
    try std.testing.expectEqual(@as(u16, 0), decoded.tab_count);
    var tabs = decoded.tabs();
    try std.testing.expectEqual(@as(?TabDescriptorType, null), tabs.next());
}

test "placements with a zero virtual id are rejected on both sides" {
    var buffer: [128]u8 = undefined;
    const placement: PlacementType = .{
        .pane_id = @enumFromInt(1),
        .revision = 3,
        .placement = .{
            .key = .{ .image_id = 7, .generation = 8 },
            .virtual_id = 0,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    };
    try std.testing.expectError(
        error.InvalidGraphicsIdentity,
        graphics.encodeGraphicsPlacement(&buffer, placement),
    );
    try std.testing.expectError(
        error.InvalidGraphicsIdentity,
        graphics.encodeGraphicsDeletePlacement(&buffer, .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .key = .{ .image_id = 7, .generation = 8 },
            .virtual_id = 0,
            .placement_id = 1,
        }),
    );

    // The same rejection from raw wire bytes: zero the virtual id inside the
    // golden payloads (tag + pane + revision + image key = 29 bytes in).
    var payload: [128]u8 = undefined;
    const virtual_id_offset = 29;
    for ([_][]const u8{ golden.graphics_placement, golden.graphics_delete_placement }) |hex| {
        const bytes = try std.fmt.hexToBytes(&payload, hex);
        @memset(bytes[virtual_id_offset..][0..8], 0);
        try std.testing.expectError(error.InvalidGraphicsIdentity, root.decodeServer(bytes));
    }
}

test "pane cwd rejects empty nul-containing and oversized paths" {
    var buffer: [types.max_cwd_bytes + 32]u8 = undefined;
    const pane_id: id_module.PaneId = @enumFromInt(1);
    try std.testing.expectError(
        error.InvalidByteString,
        pane_module.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = "" }),
    );
    try std.testing.expectError(
        error.EmbeddedNul,
        pane_module.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = "/work\x00hidden" }),
    );
    const oversized = [_]u8{'x'} ** (types.max_cwd_bytes + 1);
    try std.testing.expectError(
        error.InvalidByteString,
        pane_module.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = &oversized }),
    );
}

test "a large real-world screen fits the frame budget" {
    // 480x150 is a 5K display with a small font. The worst-case single-frame
    // bound must not reject screens that real terminals produce.
    const size: TerminalSizeType = .{ .cols = 480, .rows = 150 };
    try size.validate();

    const gpa = std.testing.allocator;
    const cells = try gpa.alloc(CellType, 480 * 150);
    defer gpa.free(cells);
    @memset(cells, .{});
    const spans = [_]SpanType{.{ .start = 0, .cells = cells }};
    const buffer = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(buffer);
    const payload = try pane_module.encodePaneFrame(buffer, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 480,
        .rows = 150,
        .scroll = .{ .total_rows = 150, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try root.decodeServer(payload)).pane_frame;
    try std.testing.expectEqual(@as(u16, 480), decoded.cols);
    try std.testing.expectEqual(@as(u16, 150), decoded.rows);
}

test "iterators over malformed view bytes return errors instead of trapping" {
    // Views carry raw encoded regions; nothing stops code from constructing
    // one over bytes the decoder never validated. Iteration must fail loudly,
    // not hit unreachable code.
    var spans = (FrameViewType{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .cursor = .{},
        .mouse = .{},
        .input_modes = .{},
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .span_count = 1,
        .encoded_spans = &.{ 0xff, 0xff },
    }).spans();
    try std.testing.expectError(error.Truncated, spans.next());

    var arguments = (LaunchViewType{
        .cwd = "/work",
        .argument_count = 1,
        .encoded_arguments = &.{0x04},
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = &.{},
    }).arguments();
    try std.testing.expectError(error.Truncated, arguments.next());
}

test "malformed cell bytes surface as errors during iteration" {
    // Build a valid frame, then corrupt the encoded cell region in ways the
    // structural decode no longer inspects: the error must appear when the
    // consumer iterates the cells.
    var buffer: [128]u8 = undefined;
    const cells = [_]CellType{.{}};
    const spans = [_]SpanType{.{ .start = 0, .cells = &cells }};
    const payload = try pane_module.encodePaneFrame(&buffer, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    });

    // Clearing the style bit of a span's first cell makes it inherit a style
    // that does not exist.
    var corrupted: [128]u8 = undefined;
    @memcpy(corrupted[0..payload.len], payload);
    const first_cell = 1 + frame.body_header_size + frame.span_header_size;
    corrupted[first_cell] &= 0x7f;
    const decoded = (try root.decodeServer(corrupted[0..payload.len])).pane_frame;
    var span_iterator = decoded.spans();
    const span = (try span_iterator.next()).?;
    var cell_iterator = span.cells();
    try std.testing.expectError(error.InvalidCell, cell_iterator.next());
}

test "the handshake fingerprint derives from the golden corpus" {
    var storage: [corpus_storage_size]u8 = undefined;
    const entries = try buildCorpus(&storage);
    const hash = fingerprint(&entries);
    var expected: handshake.SchemaId = undefined;
    expected[0..2].* = handshake.schema_version.*;
    expected[2..8].* = hash;
    std.testing.expectEqual(expected, handshake.schema_id) catch |err| {
        std.debug.print(
            "wire encoding changed: bump handshake.schema_id to \"{s}{s}\" " ++
                "(and schema_version if the change is breaking)\n",
            .{ handshake.schema_version, hash },
        );
        return err;
    };
}

// ---------------------------------------------------------------------------
// Round-trip and validation tests, moved out of messages.zig so the schema
// implementation file carries only the protocol.
// ---------------------------------------------------------------------------
test "default pane open round trips launch data without allocation" {
    const arguments = [_][]const u8{ "/bin/sh", "-l" };
    const environment = [_]EnvironmentEntryType{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "EMPTY", .value = "" },
    };
    const message = OpenPaneType{
        .request_id = @enumFromInt(9),
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/work",
            .arguments = &arguments,
            .environment_mode = .replace,
            .environment = &environment,
        },
    };

    var buffer: [512]u8 = undefined;
    const decoded = (try root.decodeClient(try pane_module.encodeOpenPane(&buffer, message))).open_pane;
    try std.testing.expectEqual(message.request_id, decoded.request_id);
    try std.testing.expect(decoded.target == .default);
    try std.testing.expectEqual(message.size, decoded.size);
    try std.testing.expectEqualStrings("/work", decoded.launch.?.cwd);
    try std.testing.expectEqual(types.EnvironmentMode.replace, decoded.launch.?.environment_mode);

    var argument_iterator = decoded.launch.?.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try argument_iterator.next()).?);
    try std.testing.expectEqualStrings("-l", (try argument_iterator.next()).?);
    try std.testing.expect((try argument_iterator.next()) == null);

    var environment_iterator = decoded.launch.?.environment();
    try std.testing.expectEqualDeep(environment[0], (try environment_iterator.next()).?);
    try std.testing.expectEqualDeep(environment[1], (try environment_iterator.next()).?);
    try std.testing.expect((try environment_iterator.next()) == null);
}

test "notifications enforce text and duration bounds before crossing IPC" {
    var buffer: [512]u8 = undefined;
    const long_title: [types.max_notification_title_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(
        error.InvalidByteString,
        notification_support.encodeShowNotification(&buffer, .{
            .request_id = @enumFromInt(1),
            .notification = .{ .title = &long_title },
        }),
    );
    try std.testing.expectError(
        error.InvalidNotificationDuration,
        notification_support.encodeNotification(&buffer, .{
            .duration_ms = types.min_notification_duration_ms - 1,
            .title = "Too brief",
        }),
    );
    try std.testing.expectError(
        error.InvalidNotificationText,
        notification_support.encodeNotification(&buffer, .{
            .title = "line one\nline two",
        }),
    );
}

test "explicit pane attachment has no launch payload" {
    var buffer: [64]u8 = undefined;
    const decoded = (try root.decodeClient(try pane_module.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(2),
        .target = .{ .pane = @enumFromInt(41) },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(41)), decoded.target.pane);
    try std.testing.expect(decoded.launch == null);
}

test "explicit workspace attachment and creation round trip" {
    var buffer: [512]u8 = undefined;
    const attached = (try root.decodeClient(try pane_module.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(2),
        .target = .{ .workspace = @enumFromInt(7) },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(id_module.WorkspaceId, @enumFromInt(7)), attached.target.workspace);
    try std.testing.expect(attached.launch == null);

    const arguments = [_][]const u8{"/bin/sh"};
    const created = (try root.decodeClient(try workspace_module.encodeCreateWorkspace(&buffer, .{
        .request_id = @enumFromInt(3),
        .size = .{ .cols = 80, .rows = 24 },
        .name = "agents",
        .launch = .{
            .cwd = "/work/project",
            .cwd_source = @enumFromInt(8),
            .arguments = &arguments,
        },
    }))).create_workspace;
    try std.testing.expectEqualStrings("agents", created.name);
    try std.testing.expectEqualStrings("/work/project", created.launch.cwd);
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(8)), created.launch.cwd_source.?);
    var iterator = created.launch.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);

    try std.testing.expectError(error.InvalidByteString, workspace_module.encodeCreateWorkspace(&buffer, .{
        .request_id = @enumFromInt(4),
        .size = .{ .cols = 80, .rows = 24 },
        .name = "",
        .launch = .{ .cwd = "/work/project", .arguments = &arguments },
    }));

    const renamed = (try root.decodeClient(try workspace_module.encodeRenameWorkspace(&buffer, .{
        .request_id = @enumFromInt(5),
        .workspace = .{ .workspace = @enumFromInt(7) },
        .name = "runtime",
    }))).rename_workspace;
    try std.testing.expectEqualStrings("runtime", renamed.name);
}

test "fixed client messages round trip" {
    var buffer: [128]u8 = undefined;

    const input = (try root.decodeClient(try pane_module.encodePaneInput(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = "abc",
    }))).pane_input;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(3)), input.pane_id);
    try std.testing.expectEqualStrings("abc", input.bytes);

    const resize = (try root.decodeClient(try pane_module.encodePaneResize(&buffer, .{
        .pane_id = @enumFromInt(3),
        .size = .{ .cols = 90, .rows = 30 },
    }))).pane_resize;
    try std.testing.expectEqual(TerminalSizeType{ .cols = 90, .rows = 30 }, resize.size);

    const ack = (try root.decodeClient(try pane_module.encodeFrameAck(&buffer, .{
        .pane_id = @enumFromInt(3),
        .frame_id = 8,
    }))).frame_ack;
    try std.testing.expectEqual(@as(u64, 8), ack.frame_id);

    const credit = (try root.decodeClient(try graphics.encodeGraphicsCredit(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = 4096,
    }))).graphics_credit;
    try std.testing.expectEqual(@as(u64, 4096), credit.bytes);
    try std.testing.expectError(error.InvalidGraphicsCredit, graphics.encodeGraphicsCredit(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = 0,
    }));

    const snapshot = (try root.decodeClient(try pane_module.encodeRequestSnapshot(&buffer, .{
        .pane_id = @enumFromInt(3),
        .known_frame_id = 7,
    }))).request_snapshot;
    try std.testing.expectEqual(@as(u64, 7), snapshot.known_frame_id);

    const detach = (try root.decodeClient(try pane_module.encodeDetachPane(&buffer, .{ .pane_id = @enumFromInt(3) }))).detach_pane;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(3)), detach.pane_id);

    try std.testing.expect((try root.decodeClient(try runtime.encodeRuntimeStop(&buffer))) == .runtime_stop);
}

test "multi-pane client messages round trip" {
    var buffer: [512]u8 = undefined;
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };

    const snapshot = (try root.decodeClient(try tab_module.encodeRequestTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(20),
        .location = location,
    }))).request_tab_snapshot;
    try std.testing.expect(std.meta.eql(location, snapshot.location));

    const created = (try root.decodeClient(try pane_module.encodeCreatePane(&buffer, .{
        .request_id = @enumFromInt(21),
        .location = location,
        .size = .{ .cols = 60, .rows = 20 },
        .launch = .{
            .cwd = "/work",
            .cwd_source = @enumFromInt(9),
            .arguments = &.{ "/bin/sh", "-l" },
        },
    }))).create_pane;
    try std.testing.expectEqual(@as(u16, 60), created.size.cols);
    try std.testing.expectEqualStrings("/work", created.launch.cwd);
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(9)), created.launch.cwd_source.?);

    try std.testing.expectError(error.InvalidPaneId, pane_module.encodeCreatePane(&buffer, .{
        .request_id = @enumFromInt(22),
        .location = location,
        .size = .{ .cols = 60, .rows = 20 },
        .launch = .{
            .cwd = "/work",
            .cwd_source = .invalid,
            .arguments = &.{"/bin/sh"},
        },
    }));

    const closed = (try root.decodeClient(try pane_module.encodeClosePane(&buffer, .{
        .request_id = @enumFromInt(22),
        .pane_id = @enumFromInt(8),
    }))).close_pane;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(8)), closed.pane_id);
}

test "tab lifecycle client messages round trip" {
    var buffer: [4096]u8 = undefined;
    const workspace: types.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const location: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(3) };

    const requested = (try root.decodeClient(try workspace_module.encodeRequestWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(40),
        .workspace = workspace,
    }))).request_workspace_snapshot;
    try std.testing.expect(std.meta.eql(workspace, requested.workspace));

    const created = (try root.decodeClient(try tab_module.encodeCreateTab(&buffer, .{
        .request_id = @enumFromInt(41),
        .workspace = workspace,
        .label = "logs",
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/work",
            .cwd_source = @enumFromInt(10),
            .arguments = &.{"/bin/sh"},
        },
    }))).create_tab;
    try std.testing.expectEqualStrings("logs", created.label);
    try std.testing.expectEqualStrings("/work", created.launch.cwd);
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(10)), created.launch.cwd_source.?);

    const renamed = (try root.decodeClient(try tab_module.encodeRenameTab(&buffer, .{
        .request_id = @enumFromInt(42),
        .location = location,
        .label = "server",
    }))).rename_tab;
    try std.testing.expectEqualStrings("server", renamed.label);

    const closed = (try root.decodeClient(try tab_module.encodeCloseTab(&buffer, .{
        .request_id = @enumFromInt(43),
        .location = location,
    }))).close_tab;
    try std.testing.expectEqualDeep(location, closed.location);

    const moved = (try root.decodeClient(try tab_module.encodeMoveTab(&buffer, .{
        .request_id = @enumFromInt(44),
        .location = location,
        .direction = .previous,
    }))).move_tab;
    try std.testing.expectEqual(types.TabMoveDirection.previous, moved.direction);
}

test "tab lifecycle server messages round trip" {
    var buffer: [4096]u8 = undefined;
    const workspace: types.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const location: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(3) };
    const descriptors = [_]TabDescriptorType{
        .{ .tab_id = @enumFromInt(3), .position = 0, .pane_count = 2, .label = "main" },
        .{ .tab_id = @enumFromInt(4), .position = 1, .pane_count = 1, .label = "logs" },
    };

    const snapshot = (try root.decodeServer(try workspace_module.encodeWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(50),
        .workspace = workspace,
        .name = "telar",
        .tabs = &descriptors,
    }))).workspace_snapshot;
    try std.testing.expectEqualStrings("telar", snapshot.name);
    var tabs = snapshot.tabs();
    try std.testing.expectEqualDeep(descriptors[0], (try tabs.next()).?);
    try std.testing.expectEqualDeep(descriptors[1], (try tabs.next()).?);
    try std.testing.expect((try tabs.next()) == null);

    const created = (try root.decodeServer(try tab_module.encodeTabCreated(&buffer, .{
        .request_id = @enumFromInt(51),
        .location = location,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(9),
    }))).tab_created;
    try std.testing.expectEqualStrings("logs", created.label);

    const renamed = (try root.decodeServer(try tab_module.encodeTabRenamed(&buffer, .{
        .request_id = @enumFromInt(52),
        .location = location,
        .label = "server",
    }))).tab_renamed;
    try std.testing.expectEqualStrings("server", renamed.label);

    const closed = (try root.decodeServer(try tab_module.encodeTabClosed(&buffer, .{
        .request_id = @enumFromInt(53),
        .location = location,
        .workspace_closed = false,
    }))).tab_closed;
    try std.testing.expect(!closed.workspace_closed);

    const lifecycle_closed = (try root.decodeServer(try tab_module.encodeTabClosed(&buffer, .{
        .request_id = .none,
        .location = location,
        .workspace_closed = true,
    }))).tab_closed;
    try std.testing.expectEqual(id_module.RequestId.none, lifecycle_closed.request_id);
    try std.testing.expect(lifecycle_closed.workspace_closed);

    const moved = (try root.decodeServer(try tab_module.encodeTabMoved(&buffer, .{
        .request_id = @enumFromInt(54),
        .location = location,
        .position = 0,
    }))).tab_moved;
    try std.testing.expectEqual(@as(u16, 0), moved.position);
}

test "history queries round trip with scopes" {
    var buffer: [2048]u8 = undefined;
    const cwd = (try root.decodeClient(try history.encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(31),
        .query = "zig build",
        .scope = .cwd,
        .scope_value = "/work/telar",
        .failed_only = true,
        .limit = 12,
    }))).query_history;
    try std.testing.expectEqualStrings("zig build", cwd.query);
    try std.testing.expectEqual(types.HistoryScope.cwd, cwd.scope);
    try std.testing.expectEqualStrings("/work/telar", cwd.scope_value);
    try std.testing.expect(cwd.failed_only);
    try std.testing.expectEqual(@as(u16, 12), cwd.limit);

    const pane = (try root.decodeClient(try history.encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(32),
        .scope = .pane,
        .pane_id = @enumFromInt(9),
    }))).query_history;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(9)), pane.pane_id);
}

test "fixed server messages round trip" {
    var buffer: [128]u8 = undefined;
    const opened = (try root.decodeServer(try pane_module.encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(5),
        .pane_id = @enumFromInt(12),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(4),
        },
        .created = true,
    }))).pane_opened;
    try std.testing.expect(opened.created);
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(12)), opened.pane_id);
    try std.testing.expectEqual(
        @as(id_module.WorkspaceId, @enumFromInt(2)),
        opened.location.workspace.workspace,
    );
    try std.testing.expectEqual(@as(id_module.TabId, @enumFromInt(4)), opened.location.tab_id);

    const worktree_opened = (try root.decodeServer(try pane_module.encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(6),
        .pane_id = @enumFromInt(13),
        .location = .{
            .workspace = .{ .worktree = @enumFromInt(3) },
            .tab_id = @enumFromInt(5),
        },
        .created = false,
    }))).pane_opened;
    try std.testing.expectEqual(
        @as(id_module.WorktreeId, @enumFromInt(3)),
        worktree_opened.location.workspace.worktree,
    );

    const exited = (try root.decodeServer(try pane_module.encodePaneExited(&buffer, .{
        .pane_id = @enumFromInt(12),
        .kind = .exited,
        .value = 7,
    }))).pane_exited;
    try std.testing.expectEqual(@as(u32, 7), exited.value);

    const failed = (try root.decodeServer(try runtime.encodeRequestFailed(&buffer, .{
        .request_id = @enumFromInt(5),
        .code = .pane_not_found,
        .message = "pane 12 does not exist",
    }))).request_failed;
    try std.testing.expectEqual(types.FailureCode.pane_not_found, failed.code);
    try std.testing.expectEqualStrings("pane 12 does not exist", failed.message);

    try std.testing.expect((try root.decodeServer(try runtime.encodeRuntimeStopping(&buffer))) == .runtime_stopping);
}

test "tab snapshots preserve ordered pane descriptors" {
    const panes = [_]PaneDescriptorType{
        .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        .{ .pane_id = @enumFromInt(9), .lifecycle = .exited },
    };
    var buffer: [128]u8 = undefined;
    const snapshot = (try root.decodeServer(try tab_module.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(4),
        .location = .{
            .workspace = .{ .worktree = @enumFromInt(2) },
            .tab_id = @enumFromInt(6),
        },
        .panes = &panes,
    }))).tab_snapshot;

    try std.testing.expectEqual(@as(u16, 2), snapshot.pane_count);
    var iterator = snapshot.panes();
    try std.testing.expectEqualDeep(panes[0], (try iterator.next()).?);
    try std.testing.expectEqualDeep(panes[1], (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);
}

test "history results preserve nullable exits and command metadata" {
    const entries = [_]HistoryEntryType{
        .{
            .id = 11,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000000000,
            .duration_ns = 42_000,
            .exit_code = 7,
            .status = .completed,
            .command = "zig build test",
            .cwd = "/work/telar",
            .workspace_path = "/work/telar",
        },
        .{
            .id = 12,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000001000,
            .duration_ns = 9,
            .exit_code = null,
            .status = .interrupted,
            .author = .agent,
            .command = "sleep 600",
            .cwd = "",
            .workspace_path = "",
        },
    };
    var buffer: [4096]u8 = undefined;
    const results = (try root.decodeServer(try history.encodeHistoryResults(&buffer, .{
        .request_id = @enumFromInt(33),
        .entries = &entries,
    }))).history_results;
    try std.testing.expectEqual(@as(u16, 2), results.entry_count);
    var iterator = results.entries();
    try std.testing.expectEqualDeep(entries[0], (try iterator.next()).?);
    try std.testing.expectEqualDeep(entries[1], (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);
}

test "pane frames use the server envelope" {
    const cells = [_]CellType{.{}};
    const spans = [_]SpanType{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    const message = FrameType{
        .pane_id = @enumFromInt(4),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .input_modes = .{ .kitty_keyboard_flags = 31, .modify_other_keys_2 = true },
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    };

    const decoded = (try root.decodeServer(try pane_module.encodePaneFrame(&buffer, message))).pane_frame;
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(4)), decoded.pane_id);
    try std.testing.expectEqualDeep(message.input_modes, decoded.input_modes);
    var span_iterator = decoded.spans();
    var cell_iterator = ((try span_iterator.next()).?).cells();
    try std.testing.expectEqualDeep(cells[0], (try cell_iterator.next()).?);
}

test "pane frames preserve every pointer shape and reject unknown wire values" {
    var buffer: [256]u8 = undefined;
    const payload = try std.fmt.hexToBytes(&buffer, golden.pane_frame);
    const pointer_offset = 1 + 24 + 4 + 5 + 3 + 8;

    for (0..256) |value| {
        payload[pointer_offset] = @intCast(value);
        if (std.enums.fromInt(frame.PointerShape, @as(u8, @intCast(value)))) |shape| {
            const decoded = (try root.decodeServer(payload)).pane_frame;
            try std.testing.expectEqual(shape, decoded.pointer_shape);
        } else {
            try std.testing.expectError(error.InvalidPointerShape, root.decodeServer(payload));
        }
    }
}

test "pane frames reject unsupported keyboard flags" {
    var buffer: [256]u8 = undefined;
    const payload = try std.fmt.hexToBytes(&buffer, golden.pane_frame);
    // Tag + pane/frame identities + geometry + cursor + mouse + six modes.
    const keyboard_flags_offset = 1 + 24 + 4 + 5 + 3 + 6;
    for ([_]u8{ 32, 64, 128, 255 }) |flags| {
        payload[keyboard_flags_offset] = flags;
        try std.testing.expectError(error.InvalidKeyboardFlags, root.decodeServer(payload));
    }
}

test "malformed application messages are rejected" {
    try std.testing.expectError(error.UnknownMessage, root.decodeClient(&.{0xff}));
    try std.testing.expectError(error.Truncated, root.decodeClient(&.{@intFromEnum(tags.ClientTag.pane_resize)}));

    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidRequestId, pane_module.encodeOpenPane(&buffer, .{
        .request_id = .none,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{ .cwd = "/tmp", .arguments = &.{"/bin/sh"} },
    }));
    try std.testing.expectError(error.EmbeddedNul, pane_module.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{"bad\x00argument"},
        },
    }));
    try std.testing.expectError(error.InvalidPaneId, pane_module.encodePaneInput(&buffer, .{
        .pane_id = .invalid,
        .bytes = "x",
    }));

    const agent_entry: AgentSnapshotEntryType = .{
        .pane_id = @enumFromInt(3),
        .pane_generation = 4,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 1,
        .process_id = 5,
        .session_id = .{0x5a} ** 16,
        .workspace_label = "telar",
        .tab_label = "main",
        .session_title = "New Codex session",
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .status = .working,
        .source = .proxy_tls,
        .authority = .active,
        .confidence = 95,
        .sequence = 6,
        .observed_at_ms = 7,
        .expires_at_ms = 8,
    };
    const duplicate_entries = [_]AgentSnapshotEntryType{ agent_entry, agent_entry };
    var agent_buffer: [1024]u8 = undefined;
    try std.testing.expectError(error.DuplicateAgentEntry, agent_module.encodeAgentSnapshot(
        &agent_buffer,
        .{ .revision = 1, .entries = &duplicate_entries },
    ));

    const single = try agent_module.encodeAgentSnapshot(
        &agent_buffer,
        .{ .revision = 1, .entries = &.{agent_entry} },
    );
    const entry_offset = 1 + @sizeOf(u64) + @sizeOf(u16);
    const entry_len = single.len - entry_offset;
    @memcpy(agent_buffer[single.len..][0..entry_len], single[entry_offset..]);
    std.mem.writeInt(u16, agent_buffer[1 + @sizeOf(u64) .. entry_offset], 2, .little);
    try std.testing.expectError(
        error.DuplicateAgentEntry,
        root.decodeServer(agent_buffer[0 .. single.len + entry_len]),
    );
}

test "agent snapshot display fields are bounded and validated before allocation" {
    const workspace = [_]u8{'w'} ** types.max_agent_workspace_label_bytes;
    const tab = [_]u8{'t'} ** types.max_tab_label_bytes;
    const title = [_]u8{'s'} ** types.max_agent_session_title_bytes;
    const cwd = [_]u8{'c'} ** types.max_agent_cwd_label_bytes;
    var entry: AgentSnapshotEntryType = .{
        .pane_id = @enumFromInt(3),
        .pane_generation = 4,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(2),
        },
        .pane_index = 1,
        .process_id = 5,
        .session_id = .{0x5a} ** 16,
        .workspace_label = &workspace,
        .tab_label = &tab,
        .session_title = &title,
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = &cwd,
        .provider = .codex,
        .status = .ready,
        .source = .screen,
        .authority = .active,
        .confidence = 95,
        .sequence = 6,
        .observed_at_ms = 7,
        .expires_at_ms = 8,
    };
    var buffer: [1024]u8 = undefined;
    const encoded = try agent_module.encodeAgentSnapshot(&buffer, .{
        .revision = 1,
        .entries = &.{entry},
    });
    var iterator = (try root.decodeServer(encoded)).agent_snapshot.entries();
    const decoded = (try iterator.next()).?;
    try std.testing.expectEqualSlices(u8, &workspace, decoded.workspace_label);
    try std.testing.expectEqualSlices(u8, &tab, decoded.tab_label);
    try std.testing.expectEqualSlices(u8, &title, decoded.session_title);
    try std.testing.expectEqualSlices(u8, &cwd, decoded.cwd_label);
    try std.testing.expect((try iterator.next()) == null);

    const workspace_too_long = [_]u8{'x'} ** (types.max_agent_workspace_label_bytes + 1);
    entry.workspace_label = &workspace_too_long;
    try std.testing.expectError(error.InvalidByteString, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 2, .entries = &.{entry} },
    ));
    entry.workspace_label = &workspace;
    const tab_too_long = [_]u8{'x'} ** (types.max_tab_label_bytes + 1);
    entry.tab_label = &tab_too_long;
    try std.testing.expectError(error.InvalidByteString, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 3, .entries = &.{entry} },
    ));
    entry.tab_label = &tab;
    const title_too_long = [_]u8{'x'} ** (types.max_agent_session_title_bytes + 1);
    entry.session_title = &title_too_long;
    try std.testing.expectError(error.InvalidByteString, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 4, .entries = &.{entry} },
    ));
    entry.session_title = &title;
    const cwd_too_long = [_]u8{'x'} ** (types.max_agent_cwd_label_bytes + 1);
    entry.cwd_label = &cwd_too_long;
    try std.testing.expectError(error.InvalidByteString, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 5, .entries = &.{entry} },
    ));
    entry.cwd_label = &cwd;
    entry.workspace_label = "bad\nlabel";
    try std.testing.expectError(error.InvalidAgentDisplayText, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 6, .entries = &.{entry} },
    ));
    entry.workspace_label = "\xff";
    try std.testing.expectError(error.InvalidUtf8, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 7, .entries = &.{entry} },
    ));
    entry.workspace_label = &workspace;
    entry.title_source = .generated;
    entry.title_state = .pending;
    try std.testing.expectError(error.InvalidAgentTitle, agent_module.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 8, .entries = &.{entry} },
    ));
}

test "truncated client and server messages are rejected" {
    var client_buffer: [256]u8 = undefined;
    const client_payload = try pane_module.encodeOpenPane(&client_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{ "/bin/sh", "-l" },
        },
    });
    for (0..client_payload.len) |length| {
        try std.testing.expectError(error.Truncated, root.decodeClient(client_payload[0..length]));
    }

    var server_buffer: [128]u8 = undefined;
    const server_payload = try pane_module.encodePaneOpened(&server_buffer, .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(2),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .created = true,
    });
    for (0..server_payload.len) |length| {
        try std.testing.expectError(error.Truncated, root.decodeServer(server_payload[0..length]));
    }
}

test "client layout schema validates trees focus and chrome-only recovery" {
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    var buffer: [types.max_client_layout_wire_bytes]u8 = undefined;
    const incomplete = [_]types.ClientLayoutNode{
        .{ .split = .{ .axis = .horizontal, .ratio = 5000 } },
        .{ .pane = .{ .id = @enumFromInt(5) } },
    };
    try std.testing.expectError(error.InvalidClientLayoutTree, layout.encodeClientLayoutUpdate(&buffer, .{
        .sidebar_visible = true,
        .sidebar_width = 62,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = &.{.{
            .location = location,
            .focused_pane = @enumFromInt(5),
            .fullscreen = false,
            .workspace_active = true,
            .nodes = &incomplete,
        }},
    }));

    const duplicate = [_]types.ClientLayoutNode{
        .{ .split = .{ .axis = .vertical, .ratio = 5000 } },
        .{ .pane = .{ .id = @enumFromInt(5) } },
        .{ .pane = .{ .id = @enumFromInt(5) } },
    };
    try std.testing.expectError(error.DuplicatePane, layout.encodeClientLayoutUpdate(&buffer, .{
        .sidebar_visible = true,
        .sidebar_width = 62,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = &.{.{
            .location = location,
            .focused_pane = @enumFromInt(5),
            .fullscreen = false,
            .workspace_active = true,
            .nodes = &duplicate,
        }},
    }));

    const pane = [_]types.ClientLayoutNode{.{ .pane = .{ .id = @enumFromInt(5) } }};
    const single_fullscreen = try layout.encodeClientLayoutUpdate(&buffer, .{
        .sidebar_visible = true,
        .sidebar_width = 62,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = &.{.{
            .location = location,
            .focused_pane = @enumFromInt(5),
            .fullscreen = true,
            .workspace_active = true,
            .nodes = &pane,
        }},
    });
    var single_tabs = (try root.decodeClient(single_fullscreen)).update_client_layout.tabs();
    const single_tab = (try single_tabs.next()).?;
    try std.testing.expect(single_tab.fullscreen);
    try std.testing.expectEqual(@as(u16, 1), single_tab.node_count);
    try std.testing.expectEqual(@as(id_module.PaneId, @enumFromInt(5)), single_tab.focused_pane);

    const chrome_only = try layout.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = false,
        .sidebar_width = 73,
        .workspace_list_collapsed = true,
    });
    const restored = (try root.decodeServer(chrome_only)).client_layout_snapshot;
    try std.testing.expect(restored.restored);
    try std.testing.expect(!restored.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 73), restored.sidebar_width);
    try std.testing.expect(restored.workspace_list_collapsed);
    try std.testing.expect(restored.active_tab == null);
    try std.testing.expectEqual(@as(u16, 0), restored.tab_count);
}

test "workspace closure handoffs are present only for a different surviving workspace" {
    var buffer: [128]u8 = undefined;
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    try std.testing.expectError(
        error.UnexpectedPreviousWorkspace,
        tab_module.encodeTabClosed(&buffer, .{
            .request_id = .none,
            .location = location,
            .workspace_closed = false,
            .previous_workspace = @enumFromInt(6),
        }),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceSuccessor,
        tab_module.encodeTabClosed(&buffer, .{
            .request_id = .none,
            .location = location,
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(7),
        }),
    );
}

test "a frame past the body budget reports FrameTooLarge, not a full buffer" {
    // max_cell_count budgets for a single span header, so a delta frame using
    // all 4096 spans of worst-case cells (unique style, full cluster) is the
    // one shape that can outgrow max_body_size on the encode side.
    const gpa = std.testing.allocator;
    const cols: u16 = 512;
    const rows: u16 = 264;
    const total: u32 = @as(u32, cols) * rows;
    const span_count = frame.max_span_count;
    const per_span = total / span_count;

    const cells = try gpa.alloc(CellType, total);
    defer gpa.free(cells);
    for (cells, 0..) |*cell, index| {
        cell.* = .{
            .len = CellType.max_bytes,
            .width = 1,
            .style = .{
                .fg = if (index % 2 == 0)
                    .{ .rgb = .{ 255, 0, 0 } }
                else
                    .{ .rgb = .{ 0, 0, 255 } },
                .bg = .{ .rgb = .{ 1, 2, 3 } },
                .underline_color = .{ .rgb = .{ 4, 5, 6 } },
            },
        };
        @memset(cell.bytes[0..CellType.max_bytes], 'a');
    }

    const spans = try gpa.alloc(SpanType, span_count);
    defer gpa.free(spans);
    for (spans, 0..) |*span, index| {
        const start: u32 = @intCast(index * per_span);
        span.* = .{ .start = start, .cells = cells[start .. start + per_span] };
    }

    // Larger than any legal frame, so the only possible failure is the budget.
    const buffer = try gpa.alloc(u8, frame.max_body_size + 128 * 1024);
    defer gpa.free(buffer);
    try std.testing.expectError(error.FrameTooLarge, pane_module.encodePaneFrame(buffer, .{
        .pane_id = try id_module.pane(7),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = cols,
        .rows = rows,
        .cursor = .{ .visible = true, .x = 0, .y = 0 },
        .mouse = .{},
        .scroll = .{ .total_rows = rows, .offset = 0 },
        .spans = spans,
    }));
}
