//! Wire-level tests for the protocol schema.
//!
//! The golden corpus below pins the exact bytes of one representative message
//! per tag in both directions. Any change to an encoding fails these tests,
//! and the handshake fingerprint is derived from the same corpus, so a wire
//! change cannot ship without a visible schema bump.

const std = @import("std");
const schema = @import("schema/root.zig");
const frame = schema.frame;
const graphics = schema.graphics;
const handshake = @import("schema/handshake.zig");
const ui = @import("ui/root.zig");

test {
    std.testing.refAllDecls(schema);
}

const Direction = enum { client, server };

const Entry = struct {
    name: []const u8,
    direction: Direction,
    /// The payload tail is raw bytes without a length prefix, so a prefix of
    /// the message can decode as a valid shorter message.
    tail_tolerant: bool = false,
    bytes: []const u8,
    golden_hex: []const u8,
};

const EntryMetadata = struct {
    name: []const u8,
    direction: Direction,
    golden_hex: []const u8,
};

const corpus_len = 88;
const corpus_storage_size = 8 * 1024;

fn buildCorpus(storage: []u8) ![corpus_len]Entry {
    var entries: [corpus_len]Entry = undefined;
    var used: usize = 0;
    var index: usize = 0;

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };

    const arguments = [_][]const u8{ "/bin/sh", "-l" };
    const environment = [_]schema.EnvironmentEntry{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "EMPTY", .value = "" },
    };
    const client_layout_nodes = [_]schema.ClientLayoutNode{
        .{ .split = .{ .axis = .horizontal, .ratio = 6000 } },
        .{ .pane = @enumFromInt(5) },
        .{ .pane = @enumFromInt(6) },
    };
    const client_layout_tabs = [_]schema.ClientTabLayout{.{
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
        try schema.encodeOpenPane(helper.space(), .{
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
        try schema.encodeOpenPane(helper.space(), .{
            .request_id = @enumFromInt(2),
            .target = .{ .pane = @enumFromInt(41) },
            .size = .{ .cols = 80, .rows = 24 },
            .launch = null,
        }),
    ));
    helper.add(.{ .name = "open_workspace", .direction = .client, .golden_hex = golden.open_workspace }, helper.commit(
        try schema.encodeOpenPane(helper.space(), .{
            .request_id = @enumFromInt(3),
            .target = .{ .workspace = @enumFromInt(7) },
            .size = .{ .cols = 80, .rows = 24 },
            .launch = null,
        }),
    ));
    helper.add(.{ .name = "create_workspace", .direction = .client, .golden_hex = golden.create_workspace }, helper.commit(
        try schema.encodeCreateWorkspace(helper.space(), .{
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
        try schema.encodeRenameWorkspace(helper.space(), .{
            .request_id = @enumFromInt(5),
            .workspace = .{ .workspace = @enumFromInt(7) },
            .name = "agents",
        }),
    ));
    helper.addTailTolerant(.{ .name = "pane_input", .direction = .client, .golden_hex = golden.pane_input }, helper.commit(
        try schema.encodePaneInput(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .bytes = "abc",
        }),
    ));
    helper.add(.{ .name = "pane_resize", .direction = .client, .golden_hex = golden.pane_resize }, helper.commit(
        try schema.encodePaneResize(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .size = .{ .cols = 90, .rows = 30 },
        }),
    ));
    helper.add(.{ .name = "frame_ack", .direction = .client, .golden_hex = golden.frame_ack }, helper.commit(
        try schema.encodeFrameAck(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .frame_id = 8,
        }),
    ));
    helper.add(.{ .name = "request_snapshot", .direction = .client, .golden_hex = golden.request_snapshot }, helper.commit(
        try schema.encodeRequestSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(3),
            .known_frame_id = 7,
        }),
    ));
    helper.add(.{ .name = "detach_pane", .direction = .client, .golden_hex = golden.detach_pane }, helper.commit(
        try schema.encodeDetachPane(helper.space(), .{ .pane_id = @enumFromInt(3) }),
    ));
    helper.add(.{ .name = "runtime_stop", .direction = .client, .golden_hex = golden.runtime_stop }, helper.commit(
        try schema.encodeRuntimeStop(helper.space()),
    ));
    helper.add(.{ .name = "request_tab_snapshot", .direction = .client, .golden_hex = golden.request_tab_snapshot }, helper.commit(
        try schema.encodeRequestTabSnapshot(helper.space(), .{
            .request_id = @enumFromInt(20),
            .location = location,
        }),
    ));
    helper.add(.{ .name = "create_pane", .direction = .client, .golden_hex = golden.create_pane }, helper.commit(
        try schema.encodeCreatePane(helper.space(), .{
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
        try schema.encodeClosePane(helper.space(), .{
            .request_id = @enumFromInt(22),
            .pane_id = @enumFromInt(8),
        }),
    ));
    helper.add(.{ .name = "query_history_cwd", .direction = .client, .golden_hex = golden.query_history_cwd }, helper.commit(
        try schema.encodeQueryHistory(helper.space(), .{
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
    const import_entries = [_]schema.ImportEntry{
        .{ .started_at_ms = 1700000002000, .command = "git status" },
        .{ .started_at_ms = 1700000003000, .command = "make -j4" },
    };
    helper.add(.{ .name = "import_history", .direction = .client, .golden_hex = golden.import_history }, helper.commit(
        try schema.encodeImportHistory(helper.space(), .{
            .request_id = @enumFromInt(34),
            .source = "zsh:/home/u/.zsh_history",
            .base_sequence = 100,
            .entries = &import_entries,
        }),
    ));
    helper.add(.{ .name = "delete_history", .direction = .client, .golden_hex = golden.delete_history }, helper.commit(
        try schema.encodeDeleteHistory(helper.space(), .{
            .request_id = @enumFromInt(35),
            .id = 11,
        }),
    ));
    helper.add(.{ .name = "prune_history", .direction = .client, .golden_hex = golden.prune_history }, helper.commit(
        try schema.encodePruneHistory(helper.space(), .{
            .request_id = @enumFromInt(36),
            .scope = .workspace,
            .scope_value = "/work/telar",
            .before_ms = 1700000000000,
            .failed_only = true,
            .match = "zig",
        }),
    ));
    helper.add(.{ .name = "read_history_output", .direction = .client, .golden_hex = golden.read_history_output }, helper.commit(
        try schema.encodeReadHistoryOutput(helper.space(), .{
            .request_id = @enumFromInt(37),
            .id = 11,
        }),
    ));
    helper.add(.{ .name = "history_stats", .direction = .client, .golden_hex = golden.history_stats }, helper.commit(
        try schema.encodeHistoryStatsQuery(helper.space(), .{
            .request_id = @enumFromInt(38),
            .scope = .workspace,
            .scope_value = "/work/telar",
            .since_ms = 1700000000000,
        }),
    ));
    helper.add(.{ .name = "query_history_pane", .direction = .client, .golden_hex = golden.query_history_pane }, helper.commit(
        try schema.encodeQueryHistory(helper.space(), .{
            .request_id = @enumFromInt(32),
            .scope = .pane,
            .pane_id = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "request_workspace_snapshot", .direction = .client, .golden_hex = golden.request_workspace_snapshot }, helper.commit(
        try schema.encodeRequestWorkspaceSnapshot(helper.space(), .{
            .request_id = @enumFromInt(40),
            .workspace = .{ .workspace = @enumFromInt(7) },
        }),
    ));
    helper.add(.{ .name = "create_tab", .direction = .client, .golden_hex = golden.create_tab }, helper.commit(
        try schema.encodeCreateTab(helper.space(), .{
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
        try schema.encodeRenameTab(helper.space(), .{
            .request_id = @enumFromInt(42),
            .location = location,
            .label = "server",
        }),
    ));
    helper.add(.{ .name = "close_tab", .direction = .client, .golden_hex = golden.close_tab }, helper.commit(
        try schema.encodeCloseTab(helper.space(), .{
            .request_id = @enumFromInt(43),
            .location = location,
        }),
    ));
    helper.add(.{ .name = "move_tab", .direction = .client, .golden_hex = golden.move_tab }, helper.commit(
        try schema.encodeMoveTab(helper.space(), .{
            .request_id = @enumFromInt(44),
            .location = location,
            .direction = .previous,
        }),
    ));
    helper.add(.{ .name = "request_graphics_snapshot", .direction = .client, .golden_hex = golden.request_graphics_snapshot }, helper.commit(
        try schema.encodeRequestGraphicsSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(5),
        }),
    ));
    helper.add(.{ .name = "graphics_credit", .direction = .client, .golden_hex = golden.graphics_credit }, helper.commit(
        try schema.encodeGraphicsCredit(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .bytes = 4096,
        }),
    ));
    helper.add(.{ .name = "configure_graphics", .direction = .client, .golden_hex = golden.configure_graphics }, helper.commit(
        try schema.encodeConfigureGraphics(helper.space(), .{
            .shared = true,
        }),
    ));
    helper.add(.{ .name = "request_runtime_state", .direction = .client, .golden_hex = golden.request_runtime_state }, helper.commit(
        try schema.encodeRequestRuntimeState(helper.space(), .{
            .client_identity = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "set_pane_viewport", .direction = .client, .golden_hex = golden.set_pane_viewport }, helper.commit(
        try schema.encodeSetPaneViewport(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .offset = 42,
        }),
    ));
    helper.add(.{ .name = "copy_selection", .direction = .client, .golden_hex = golden.copy_selection }, helper.commit(
        try schema.encodeCopySelection(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .start_x = 1,
            .start_y = 2,
            .end_x = 3,
            .end_y = 4,
            .linewise = true,
        }),
    ));
    helper.add(.{ .name = "show_notification", .direction = .client, .golden_hex = golden.show_notification }, helper.commit(
        try schema.encodeShowNotification(helper.space(), .{
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
        try schema.encodeClientLayoutUpdate(helper.space(), .{
            .sidebar_visible = true,
            .sidebar_width = 73,
            .workspace_list_collapsed = true,
            .active_tab = location,
            .tabs = &client_layout_tabs,
        }),
    ));
    helper.add(.{ .name = "acknowledge_agent", .direction = .client, .golden_hex = golden.acknowledge_agent }, helper.commit(
        try schema.encodeAcknowledgeAgent(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
        }),
    ));
    helper.add(.{ .name = "query_agents", .direction = .client, .golden_hex = golden.query_agents }, helper.commit(
        try schema.encodeQueryAgents(helper.space(), .{ .request_id = @enumFromInt(5) }),
    ));
    helper.add(.{ .name = "read_pane", .direction = .client, .golden_hex = golden.read_pane }, helper.commit(
        try schema.encodeReadPane(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .rows = 40,
            .source = .recent,
        }),
    ));
    helper.add(.{ .name = "send_pane_text", .direction = .client, .golden_hex = golden.send_pane_text }, helper.commit(
        try schema.encodeSendPaneText(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .mode = .prompt,
            .text = "ls",
        }),
    ));
    helper.add(.{ .name = "report_agent_session", .direction = .client, .golden_hex = golden.report_agent_session }, helper.commit(
        try schema.encodeReportAgentSession(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .session = "abc",
        }),
    ));
    helper.add(.{ .name = "report_agent", .direction = .client, .golden_hex = golden.report_agent }, helper.commit(
        try schema.encodeReportAgent(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .state = .blocked,
            .session = "abc",
        }),
    ));
    helper.add(.{ .name = "report_agent_command", .direction = .client, .golden_hex = golden.report_agent_command }, helper.commit(
        try schema.encodeReportAgentCommand(helper.space(), .{
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
        try schema.encodeReportAgentTitle(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .title = "Fix proxy",
        }),
    ));
    helper.add(.{ .name = "search_pane", .direction = .client, .golden_hex = golden.search_pane }, helper.commit(
        try schema.encodeSearchPane(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .needle = "err",
        }),
    ));
    helper.add(.{ .name = "request_pane_focus", .direction = .client, .golden_hex = golden.request_pane_focus }, helper.commit(
        try schema.encodeRequestPaneFocus(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .direction = .left,
        }),
    ));
    helper.add(.{ .name = "complete_pane_focus", .direction = .client, .golden_hex = golden.complete_pane_focus }, helper.commit(
        try schema.encodeCompletePaneFocus(helper.space(), .{
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
        try schema.encodePaneOpened(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(12),
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(4),
            },
            .created = true,
        }),
    ));
    const frame_cells = [_]ui.Cell{
        .{},
        .{
            .bytes = [_]u8{'x'} ++ [_]u8{0} ** (ui.Cell.max_bytes - 1),
            .len = 1,
            .width = 1,
            .style = .{
                .fg = .{ .rgb = .{ 1, 2, 3 } },
                .bg = .{ .indexed = 4 },
                .flags = .{ .bold = true, .underline = .curly },
            },
        },
    };
    const frame_spans = [_]frame.Span{.{ .start = 0, .cells = &frame_cells }};
    helper.add(.{ .name = "pane_frame", .direction = .server, .golden_hex = golden.pane_frame }, helper.commit(
        try schema.encodePaneFrame(helper.space(), .{
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
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &frame_spans,
        }),
    ));
    helper.add(.{ .name = "pane_exited", .direction = .server, .golden_hex = golden.pane_exited }, helper.commit(
        try schema.encodePaneExited(helper.space(), .{
            .pane_id = @enumFromInt(12),
            .kind = .exited,
            .value = 7,
        }),
    ));
    helper.addTailTolerant(.{ .name = "request_failed", .direction = .server, .golden_hex = golden.request_failed }, helper.commit(
        try schema.encodeRequestFailed(helper.space(), .{
            .request_id = @enumFromInt(5),
            .code = .pane_not_found,
            .message = "pane 12 does not exist",
        }),
    ));
    helper.add(.{ .name = "runtime_stopping", .direction = .server, .golden_hex = golden.runtime_stopping }, helper.commit(
        try schema.encodeRuntimeStopping(helper.space()),
    ));
    const panes = [_]schema.PaneDescriptor{
        .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        .{ .pane_id = @enumFromInt(9), .lifecycle = .exited },
    };
    helper.add(.{ .name = "tab_snapshot", .direction = .server, .golden_hex = golden.tab_snapshot }, helper.commit(
        try schema.encodeTabSnapshot(helper.space(), .{
            .request_id = @enumFromInt(4),
            .location = .{
                .workspace = .{ .worktree = @enumFromInt(2) },
                .tab_id = @enumFromInt(6),
            },
            .panes = &panes,
        }),
    ));
    const history_entries = [_]schema.HistoryEntry{
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
        try schema.encodeHistoryOutput(helper.space(), .{
            .request_id = @enumFromInt(37),
            .id = 11,
            .truncated = true,
            .observed_bytes = 9000,
            .content = "error: exit 1\n",
        }),
    ));
    const stats_top = [_]schema.HistoryStatsTop{
        .{ .count = 30, .command = "git status" },
        .{ .count = 12, .command = "zig build" },
    };
    helper.add(.{ .name = "history_stats_result", .direction = .server, .golden_hex = golden.history_stats_result }, helper.commit(
        try schema.encodeHistoryStats(helper.space(), .{
            .request_id = @enumFromInt(38),
            .total = 120,
            .unique = 40,
            .top = &stats_top,
        }),
    ));
    helper.add(.{ .name = "history_pruned", .direction = .server, .golden_hex = golden.history_pruned }, helper.commit(
        try schema.encodeHistoryPruned(helper.space(), .{
            .request_id = @enumFromInt(36),
            .removed = 3,
        }),
    ));
    helper.add(.{ .name = "history_results", .direction = .server, .golden_hex = golden.history_results }, helper.commit(
        try schema.encodeHistoryResults(helper.space(), .{
            .request_id = @enumFromInt(33),
            .entries = &history_entries,
        }),
    ));
    helper.add(.{ .name = "suggest_command", .direction = .client, .golden_hex = golden.suggest_command }, helper.commit(
        try schema.encodeSuggestCommand(helper.space(), .{
            .request_id = @enumFromInt(41),
            .pane_id = @enumFromInt(9),
            .text = "list files by size",
        }),
    ));
    helper.add(.{ .name = "command_suggestion", .direction = .server, .golden_hex = golden.command_suggestion }, helper.commit(
        try schema.encodeCommandSuggestion(helper.space(), .{
            .request_id = @enumFromInt(41),
            .status = .ready,
            .text = "ls -lS",
        }),
    ));
    const descriptors = [_]schema.TabDescriptor{
        .{ .tab_id = @enumFromInt(3), .position = 0, .pane_count = 2, .label = "main" },
        .{ .tab_id = @enumFromInt(4), .position = 1, .pane_count = 1, .label = "logs" },
    };
    helper.add(.{ .name = "workspace_snapshot", .direction = .server, .golden_hex = golden.workspace_snapshot }, helper.commit(
        try schema.encodeWorkspaceSnapshot(helper.space(), .{
            .request_id = @enumFromInt(50),
            .workspace = .{ .workspace = @enumFromInt(7) },
            .name = "telar",
            .tabs = &descriptors,
        }),
    ));
    helper.add(.{ .name = "tab_created", .direction = .server, .golden_hex = golden.tab_created }, helper.commit(
        try schema.encodeTabCreated(helper.space(), .{
            .request_id = @enumFromInt(51),
            .location = location,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(9),
        }),
    ));
    helper.add(.{ .name = "tab_renamed", .direction = .server, .golden_hex = golden.tab_renamed }, helper.commit(
        try schema.encodeTabRenamed(helper.space(), .{
            .request_id = @enumFromInt(52),
            .location = location,
            .label = "server",
        }),
    ));
    helper.add(.{ .name = "tab_closed", .direction = .server, .golden_hex = golden.tab_closed }, helper.commit(
        try schema.encodeTabClosed(helper.space(), .{
            .request_id = .none,
            .location = location,
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(6),
        }),
    ));
    helper.add(.{ .name = "tab_moved", .direction = .server, .golden_hex = golden.tab_moved }, helper.commit(
        try schema.encodeTabMoved(helper.space(), .{
            .request_id = @enumFromInt(54),
            .location = location,
            .position = 0,
        }),
    ));
    helper.add(.{ .name = "resync_required", .direction = .server, .golden_hex = golden.resync_required }, helper.commit(
        try schema.encodeResyncRequired(helper.space(), .{
            .workspace = .{ .workspace = @enumFromInt(7) },
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(6),
        }),
    ));
    helper.add(.{ .name = "graphics_snapshot", .direction = .server, .golden_hex = golden.graphics_snapshot }, helper.commit(
        try schema.encodeGraphicsSnapshot(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .phase = .begin,
        }),
    ));
    helper.add(.{ .name = "graphics_image", .direction = .server, .golden_hex = golden.graphics_image }, helper.commit(
        try schema.encodeGraphicsImage(helper.space(), .{
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
        try schema.encodeGraphicsImageChunk(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .key = .{ .image_id = 7, .generation = 8 },
            .offset = 0,
            .bytes = &.{ 1, 2, 3, 4 },
        }),
    ));
    helper.add(.{ .name = "graphics_shared_image", .direction = .server, .golden_hex = golden.graphics_shared_image }, helper.commit(
        try schema.encodeGraphicsSharedImage(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 3,
            .image = .{
                .key = .{ .image_id = 7, .generation = 8 },
                .format = .rgba,
                .width = 2,
                .height = 2,
                .byte_len = 16,
            },
            .name = try graphics.ShmName.init("/tlr0000002a-7"),
        }),
    ));
    helper.add(.{ .name = "graphics_placement", .direction = .server, .golden_hex = golden.graphics_placement }, helper.commit(
        try schema.encodeGraphicsPlacement(helper.space(), .{
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
        try schema.encodeGraphicsDeleteImage(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 4,
            .key = .{ .image_id = 7, .generation = 8 },
        }),
    ));
    helper.add(.{ .name = "graphics_delete_placement", .direction = .server, .golden_hex = golden.graphics_delete_placement }, helper.commit(
        try schema.encodeGraphicsDeletePlacement(helper.space(), .{
            .pane_id = @enumFromInt(1),
            .revision = 5,
            .key = .{ .image_id = 7, .generation = 8 },
            .virtual_id = 1,
            .placement_id = 1,
        }),
    ));
    helper.add(.{ .name = "proxy_status", .direction = .server, .golden_hex = golden.proxy_status }, helper.commit(
        try schema.encodeProxyStatus(helper.space(), .{ .active = true, .scope = .wildcard, .system_trusted = true }),
    ));
    const agent_entries = [_]schema.AgentSnapshotEntry{.{
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
        try schema.encodeAgentSnapshot(helper.space(), .{
            .revision = 9,
            .entries = &agent_entries,
        }),
    ));
    helper.add(.{ .name = "system_metrics", .direction = .server, .golden_hex = golden.system_metrics }, helper.commit(
        try schema.encodeSystemMetrics(helper.space(), .{
            .revision = 5,
            .cpu_percent = 42,
            .memory_used_decigib = 92,
            .has_battery = true,
            .battery_percent = 84,
        }),
    ));
    const workspace_list_entries = [_]schema.WorkspaceListEntry{
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
        try schema.encodeWorkspaceList(helper.space(), .{
            .revision = 3,
            .entries = &workspace_list_entries,
        }),
    ));
    helper.add(.{ .name = "pane_cwd", .direction = .server, .golden_hex = golden.pane_cwd }, helper.commit(
        try schema.encodePaneCwd(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .cwd = "/work/telar",
        }),
    ));
    helper.add(.{ .name = "pane_foreground", .direction = .server, .golden_hex = golden.pane_foreground }, helper.commit(
        try schema.encodePaneForeground(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .name = "zsh",
        }),
    ));
    helper.add(.{ .name = "pane_clipboard", .direction = .server, .golden_hex = golden.pane_clipboard }, helper.commit(
        try schema.encodePaneClipboard(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .bytes = "abc",
        }),
    ));
    helper.add(.{ .name = "notification", .direction = .server, .golden_hex = golden.notification }, helper.commit(
        try schema.encodeNotification(helper.space(), .{
            .level = .warning,
            .duration_ms = 3000,
            .target = .{ .tab = @enumFromInt(3) },
            .title = "Agent waiting",
            .message = "Review its question",
        }),
    ));
    helper.add(.{ .name = "notification_shown", .direction = .server, .golden_hex = golden.notification_shown }, helper.commit(
        try schema.encodeNotificationShown(helper.space(), .{
            .request_id = @enumFromInt(46),
            .delivered_clients = 2,
        }),
    ));
    helper.add(.{ .name = "agent_sound", .direction = .server, .golden_hex = golden.agent_sound }, helper.commit(
        try schema.encodeAgentSound(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .pane_generation = 7,
            .sound = .needs_input,
        }),
    ));
    helper.add(.{ .name = "client_layout_snapshot", .direction = .server, .golden_hex = golden.client_layout_snapshot }, helper.commit(
        try schema.encodeClientLayoutSnapshot(helper.space(), .{
            .restored = true,
            .sidebar_visible = true,
            .sidebar_width = 73,
            .workspace_list_collapsed = true,
            .active_tab = location,
            .tabs = &client_layout_tabs,
        }),
    ));
    helper.add(.{ .name = "pane_text", .direction = .server, .golden_hex = golden.pane_text }, helper.commit(
        try schema.encodePaneText(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .truncated = false,
            .text = "hi",
        }),
    ));
    helper.add(.{ .name = "request_completed", .direction = .server, .golden_hex = golden.request_completed }, helper.commit(
        try schema.encodeRequestCompleted(helper.space(), .{ .request_id = @enumFromInt(5) }),
    ));
    helper.add(.{ .name = "pane_title", .direction = .server, .golden_hex = golden.pane_title }, helper.commit(
        try schema.encodePaneTitle(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .title = "vim",
        }),
    ));
    helper.add(.{ .name = "pane_progress", .direction = .server, .golden_hex = golden.pane_progress }, helper.commit(
        try schema.encodePaneProgress(helper.space(), .{
            .pane_id = @enumFromInt(5),
            .state = .set,
            .percent = 42,
        }),
    ));
    helper.add(.{ .name = "pane_matches", .direction = .server, .golden_hex = golden.pane_matches }, helper.commit(
        try schema.encodePaneMatches(helper.space(), .{
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .truncated = false,
            .matches = &.{.{ .x = 2, .y = 7, .len = 3 }},
        }),
    ));
    helper.add(.{ .name = "pane_focus_command", .direction = .server, .golden_hex = golden.pane_focus_command }, helper.commit(
        try schema.encodePaneFocusCommand(helper.space(), .{
            .requester = .{ .id = 9, .generation = 10 },
            .request_id = @enumFromInt(5),
            .pane_id = @enumFromInt(5),
            .pane_generation = 3,
            .direction = .left,
        }),
    ));
    helper.add(.{ .name = "pane_focus_result", .direction = .server, .golden_hex = golden.pane_focus_result }, helper.commit(
        try schema.encodePaneFocusResult(helper.space(), .{
            .request_id = @enumFromInt(5),
            .outcome = .focused,
            .focused_pane_id = @enumFromInt(6),
        }),
    ));

    std.debug.assert(index == corpus_len);
    return entries;
}

/// One hex string per corpus entry, in corpus order. Regenerate with the
/// "GOLDEN" print block below when an encoding change is intentional, and
/// bump `handshake.schema_id` to the new fingerprint in the same commit.
const golden = struct {
    pub const open_pane_default = "01090000000000000000780028000800100005002f776f726b0000000000000000020007002f62696e2f736802002d6c01020004005445524d0e000000787465726d2d323536636f6c6f720500454d50545900000000";
    pub const open_pane_attach = "0102000000000000000129000000000000005000180000000000";
    pub const open_workspace = "0103000000000000000207000000000000005000180000000000";
    pub const create_workspace = "150400000000000000500018000000000006006167656e747305002f776f726b0500000000000000020007002f62696e2f736802002d6c01020004005445524d0e000000787465726d2d323536636f6c6f720500454d50545900000000";
    pub const rename_workspace = "16050000000000000000070000000000000006006167656e7473";
    pub const pane_input = "020300000000000000616263";
    pub const pane_resize = "0303000000000000005a001e0000000000";
    pub const frame_ack = "0403000000000000000800000000000000";
    pub const request_snapshot = "0503000000000000000700000000000000";
    pub const detach_pane = "060300000000000000";
    pub const runtime_stop = "07";
    pub const request_tab_snapshot = "0814000000000000000007000000000000000300000000000000";
    pub const create_pane = "09150000000000000000070000000000000003000000000000003c0014000000000005002f776f726b0600000000000000010007002f62696e2f7368000000";
    pub const close_pane = "0a16000000000000000800000000000000";
    pub const query_history_cwd = "0b1f0000000000000009007a6967206275696c64010b002f776f726b2f74656c6172010001010c00";
    pub const history_stats = "262600000000000000020b002f776f726b2f74656c61720068e5cf8b010000";
    pub const history_stats_result = "a6260000000000000078000000000000002800000000000000021e000000000000000a00676974207374617475730c0000000000000009007a6967206275696c64";
    pub const read_history_output = "2525000000000000000b00000000000000";
    pub const history_output = "a525000000000000000b000000000000000128230000000000000e0000006572726f723a206578697420310a";
    pub const delete_history = "2323000000000000000b00000000000000";
    pub const prune_history = "242400000000000000020b002f776f726b2f74656c61720068e5cf8b0100000103007a6967";
    pub const history_pruned = "a424000000000000000300000000000000";
    pub const import_history = "22220000000000000018007a73683a2f686f6d652f752f2e7a73685f686973746f727964000000000000000200d06fe5cf8b0100000a0067697420737461747573b873e5cf8b01000008006d616b65202d6a34";
    pub const query_history_pane = "0b20000000000000000000030900000000000000000000001400";
    pub const request_workspace_snapshot = "0c2800000000000000000700000000000000";
    pub const create_tab = "0d290000000000000000070000000000000004006c6f6773500018000000000005002f776f726b0700000000000000010007002f62696e2f7368000000";
    pub const rename_tab = "0e2a0000000000000000070000000000000003000000000000000600736572766572";
    pub const close_tab = "0f2b000000000000000007000000000000000300000000000000";
    pub const move_tab = "102c00000000000000000700000000000000030000000000000000";
    pub const request_graphics_snapshot = "110500000000000000";
    pub const graphics_credit = "1205000000000000000010000000000000";
    pub const configure_graphics = "1301";
    pub const request_runtime_state = "140900000000000000";
    pub const set_pane_viewport = "1705000000000000002a000000";
    pub const copy_selection = "18050000000000000001000200000003000400000001";
    pub const show_notification = "192d0000000000000001c40900000105000000000000000e004275696c6420636f6d706c6574650d004f70656e207468652070616e65";
    pub const update_client_layout = "1a0149000100070000000000000003000000000000000100000700000000000000030000000000000005000000000000000001030001007017000500000000000000000600000000000000";
    pub const acknowledge_agent = "1b05000000000000000300000000000000";
    pub const query_agents = "1c0500000000000000";
    pub const read_pane = "1d0500000000000000050000000000000003000000000000002800" ++ "01";
    pub const send_pane_text = "1e0500000000000000050000000000000003000000000000000102006c73";
    pub const report_agent_session = "1f0500000000000000050000000000000003000000000000000300616263";
    pub const report_agent = "20050000000000000005000000000000000300000000000000010300616263000000";
    pub const report_agent_command = "2a050000000000000005000000000000000300000000000000010500636f646578060063616c6c2d370e0000007a6967206275696c64207465737405002f776f726b03006162630107000000";
    pub const report_agent_title = "2b05000000000000000500000000000000030000000000000009004669782070726f7879";
    pub const search_pane = "21050000000000000005000000000000000300657272";
    pub const request_pane_focus = "2705000000000000000500000000000000030000000000000000";
    pub const complete_pane_focus = "2809000000000000000a00000000000000050000000000000005000000000000000300000000000000000600000000000000";
    pub const pane_matches = "a3050000000000000005000000000000000001000200070000000300";
    pub const pane_text = "a00500000000000000050000000000000000020000006869";
    pub const request_completed = "a10500000000000000";
    pub const pane_title = "a20500000000000000030076696d";
    pub const pane_progress = "aa0500000000000000012a";
    pub const pane_opened = "8105000000000000000c00000000000000000200000000000000040000000000000001";
    pub const pane_frame = "82040000000000000001000000000000000000000000000000020001000101000000000000000000010000050101000000000000000100000000000200000012000000a1000000000020a101030201020301040078";
    pub const pane_exited = "830c000000000000000007000000";
    pub const request_failed = "840500000000000000010070616e6520313220646f6573206e6f74206578697374";
    pub const runtime_stopping = "85";
    pub const tab_snapshot = "86040000000000000001020000000000000006000000000000000200030000000000000000090000000000000001";
    pub const history_results = "87210000000000000002000b0000000000000003000000000000000068e5cf8b01000010a4000000000000010700000000000000000e0000007a6967206275696c6420746573740b002f776f726b2f74656c61720b002f776f726b2f74656c61720c000000000000000300000000000000e86be5cf8b010000090000000000000000010100000009000000736c656570203630300b002f776f726b2f74656c61720b002f776f726b2f74656c6172";
    pub const workspace_snapshot = "883200000000000000000700000000000000050074656c6172020003000000000000000000020004006d61696e04000000000000000100010004006c6f6773";
    pub const tab_created = "8933000000000000000007000000000000000300000000000000010004006c6f67730900000000000000";
    pub const tab_renamed = "8a340000000000000000070000000000000003000000000000000600736572766572";
    pub const tab_closed = "8b0000000000000000000700000000000000030000000000000001010600000000000000";
    pub const tab_moved = "8c360000000000000000070000000000000003000000000000000000";
    pub const resync_required = "9300070000000000000001010600000000000000";
    pub const graphics_snapshot = "8d0100000000000000030000000000000000";
    pub const graphics_image = "8e010000000000000003000000000000000700000008000000000000002002000000020000001000000000000000";
    pub const graphics_image_chunk = "8f0100000000000000030000000000000007000000080000000000000000000000000000000400000001020304";
    pub const graphics_shared_image = "940100000000000000030000000000000007000000080000000000000020020000000200000010000000000000000e0000002f746c7230303030303032612d37";
    pub const graphics_placement = "90010000000000000003000000000000000700000008000000000000000100000000000000010000000200000003000000000000000000000002000000020000000100000001000000000000000000000000000000";
    pub const graphics_delete_image = "9101000000000000000400000000000000070000000800000000000000";
    pub const graphics_delete_placement = "9201000000000000000500000000000000070000000800000000000000010000000000000001000000";
    pub const proxy_status = "95010101";
    pub const agent_snapshot = "960900000000000000010005000000000000000700000000000000000200000000000000040000000000000003002a0000000102030405060708090a0b0c0d0e0f10050074656c61720600746573742d321500496d70726f7665206167656e7420636f6e7465787401020f007e2f73616e64626f782f74656c6172020500636f6465780500436f646578010058010102015f0b00000000000000e803000000000000d007000000000000";
    pub const system_metrics = "9705000000000000002a5c000154";
    pub const workspace_list = "98030000000000000002000700000000000000050074656c61720b002f776f726b2f74656c617202000400" ++ "6d61696e" ++ "01" ++ "090000000000000003006170690900" ++ "2f776f726b2f617069" ++ "0100" ++ "0000" ++ "00";
    pub const pane_cwd = "9905000000000000000b002f776f726b2f74656c6172";
    pub const pane_foreground = "9d050000000000000003007a7368";
    pub const pane_clipboard = "9a050000000000000003000000616263";
    pub const notification = "9b02b80b00000203000000000000000d004167656e742077616974696e67130052657669657720697473207175657374696f6e";
    pub const notification_shown = "9c2e0000000000000002";
    pub const agent_sound = "9e0500000000000000070000000000000001";
    pub const client_layout_snapshot = "9f01014900010100070000000000000003000000000000000100000700000000000000030000000000000005000000000000000001030001007017000500000000000000000600000000000000";
    pub const pane_focus_command = "a709000000000000000a0000000000000005000000000000000500000000000000030000000000000000";
    pub const pane_focus_result = "a80500000000000000000600000000000000";
    pub const suggest_command = "292900000000000000090000000000000012006c6973742066696c65732062792073697a65";
    pub const command_suggestion = "a929000000000000000006006c73202d6c53";
};

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
        .client => _ = try schema.decodeClient(payload),
        .server => _ = try schema.decodeServer(payload),
    }
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
    const decoded = (try schema.decodeServer(try schema.encodeWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(60),
        .workspace = .{ .workspace = @enumFromInt(7) },
        .name = "telar",
        .tabs = &.{},
    }))).workspace_snapshot;
    try std.testing.expectEqualStrings("telar", decoded.name);
    try std.testing.expectEqual(@as(u16, 0), decoded.tab_count);
    var tabs = decoded.tabs();
    try std.testing.expectEqual(@as(?schema.TabDescriptor, null), tabs.next());
}

test "placements with a zero virtual id are rejected on both sides" {
    var buffer: [128]u8 = undefined;
    const placement: graphics.Placement = .{
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
        schema.encodeGraphicsPlacement(&buffer, placement),
    );
    try std.testing.expectError(
        error.InvalidGraphicsIdentity,
        schema.encodeGraphicsDeletePlacement(&buffer, .{
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
        try std.testing.expectError(error.InvalidGraphicsIdentity, schema.decodeServer(bytes));
    }
}

test "pane cwd rejects empty nul-containing and oversized paths" {
    var buffer: [schema.max_cwd_bytes + 32]u8 = undefined;
    const pane_id: schema.PaneId = @enumFromInt(1);
    try std.testing.expectError(
        error.InvalidByteString,
        schema.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = "" }),
    );
    try std.testing.expectError(
        error.EmbeddedNul,
        schema.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = "/work\x00hidden" }),
    );
    const oversized = [_]u8{'x'} ** (schema.max_cwd_bytes + 1);
    try std.testing.expectError(
        error.InvalidByteString,
        schema.encodePaneCwd(&buffer, .{ .pane_id = pane_id, .cwd = &oversized }),
    );
}

test "a large real-world screen fits the frame budget" {
    // 480x150 is a 5K display with a small font. The worst-case single-frame
    // bound must not reject screens that real terminals produce.
    const size: schema.TerminalSize = .{ .cols = 480, .rows = 150 };
    try size.validate();

    const gpa = std.testing.allocator;
    const cells = try gpa.alloc(ui.Cell, 480 * 150);
    defer gpa.free(cells);
    @memset(cells, .{});
    const spans = [_]frame.Span{.{ .start = 0, .cells = cells }};
    const buffer = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(buffer);
    const payload = try schema.encodePaneFrame(buffer, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 480,
        .rows = 150,
        .scroll = .{ .total_rows = 150, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try schema.decodeServer(payload)).pane_frame;
    try std.testing.expectEqual(@as(u16, 480), decoded.cols);
    try std.testing.expectEqual(@as(u16, 150), decoded.rows);
}

test "iterators over malformed view bytes return errors instead of trapping" {
    // Views carry raw encoded regions; nothing stops code from constructing
    // one over bytes the decoder never validated. Iteration must fail loudly,
    // not hit unreachable code.
    var spans = (frame.FrameView{
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

    var arguments = (schema.LaunchView{
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
    const cells = [_]ui.Cell{.{}};
    const spans = [_]frame.Span{.{ .start = 0, .cells = &cells }};
    const payload = try schema.encodePaneFrame(&buffer, .{
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
    const decoded = (try schema.decodeServer(corrupted[0..payload.len])).pane_frame;
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
    const environment = [_]schema.EnvironmentEntry{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "EMPTY", .value = "" },
    };
    const message = schema.OpenPane{
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
    const decoded = (try schema.decodeClient(try schema.encodeOpenPane(&buffer, message))).open_pane;
    try std.testing.expectEqual(message.request_id, decoded.request_id);
    try std.testing.expect(decoded.target == .default);
    try std.testing.expectEqual(message.size, decoded.size);
    try std.testing.expectEqualStrings("/work", decoded.launch.?.cwd);
    try std.testing.expectEqual(schema.EnvironmentMode.replace, decoded.launch.?.environment_mode);

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
    const long_title: [schema.max_notification_title_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(
        error.InvalidByteString,
        schema.encodeShowNotification(&buffer, .{
            .request_id = @enumFromInt(1),
            .notification = .{ .title = &long_title },
        }),
    );
    try std.testing.expectError(
        error.InvalidNotificationDuration,
        schema.encodeNotification(&buffer, .{
            .duration_ms = schema.min_notification_duration_ms - 1,
            .title = "Too brief",
        }),
    );
    try std.testing.expectError(
        error.InvalidNotificationText,
        schema.encodeNotification(&buffer, .{
            .title = "line one\nline two",
        }),
    );
}

test "explicit pane attachment has no launch payload" {
    var buffer: [64]u8 = undefined;
    const decoded = (try schema.decodeClient(try schema.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(2),
        .target = .{ .pane = @enumFromInt(41) },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(41)), decoded.target.pane);
    try std.testing.expect(decoded.launch == null);
}

test "explicit workspace attachment and creation round trip" {
    var buffer: [512]u8 = undefined;
    const attached = (try schema.decodeClient(try schema.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(2),
        .target = .{ .workspace = @enumFromInt(7) },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(7)), attached.target.workspace);
    try std.testing.expect(attached.launch == null);

    const arguments = [_][]const u8{"/bin/sh"};
    const created = (try schema.decodeClient(try schema.encodeCreateWorkspace(&buffer, .{
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
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(8)), created.launch.cwd_source.?);
    var iterator = created.launch.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);

    try std.testing.expectError(error.InvalidByteString, schema.encodeCreateWorkspace(&buffer, .{
        .request_id = @enumFromInt(4),
        .size = .{ .cols = 80, .rows = 24 },
        .name = "",
        .launch = .{ .cwd = "/work/project", .arguments = &arguments },
    }));

    const renamed = (try schema.decodeClient(try schema.encodeRenameWorkspace(&buffer, .{
        .request_id = @enumFromInt(5),
        .workspace = .{ .workspace = @enumFromInt(7) },
        .name = "runtime",
    }))).rename_workspace;
    try std.testing.expectEqualStrings("runtime", renamed.name);
}

test "fixed client messages round trip" {
    var buffer: [128]u8 = undefined;

    const input = (try schema.decodeClient(try schema.encodePaneInput(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = "abc",
    }))).pane_input;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(3)), input.pane_id);
    try std.testing.expectEqualStrings("abc", input.bytes);

    const resize = (try schema.decodeClient(try schema.encodePaneResize(&buffer, .{
        .pane_id = @enumFromInt(3),
        .size = .{ .cols = 90, .rows = 30 },
    }))).pane_resize;
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 90, .rows = 30 }, resize.size);

    const ack = (try schema.decodeClient(try schema.encodeFrameAck(&buffer, .{
        .pane_id = @enumFromInt(3),
        .frame_id = 8,
    }))).frame_ack;
    try std.testing.expectEqual(@as(u64, 8), ack.frame_id);

    const credit = (try schema.decodeClient(try schema.encodeGraphicsCredit(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = 4096,
    }))).graphics_credit;
    try std.testing.expectEqual(@as(u64, 4096), credit.bytes);
    try std.testing.expectError(error.InvalidGraphicsCredit, schema.encodeGraphicsCredit(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = 0,
    }));

    const snapshot = (try schema.decodeClient(try schema.encodeRequestSnapshot(&buffer, .{
        .pane_id = @enumFromInt(3),
        .known_frame_id = 7,
    }))).request_snapshot;
    try std.testing.expectEqual(@as(u64, 7), snapshot.known_frame_id);

    const detach = (try schema.decodeClient(try schema.encodeDetachPane(&buffer, .{ .pane_id = @enumFromInt(3) }))).detach_pane;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(3)), detach.pane_id);

    try std.testing.expect((try schema.decodeClient(try schema.encodeRuntimeStop(&buffer))) == .runtime_stop);
}

test "multi-pane client messages round trip" {
    var buffer: [512]u8 = undefined;
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };

    const snapshot = (try schema.decodeClient(try schema.encodeRequestTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(20),
        .location = location,
    }))).request_tab_snapshot;
    try std.testing.expect(std.meta.eql(location, snapshot.location));

    const created = (try schema.decodeClient(try schema.encodeCreatePane(&buffer, .{
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
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(9)), created.launch.cwd_source.?);

    try std.testing.expectError(error.InvalidPaneId, schema.encodeCreatePane(&buffer, .{
        .request_id = @enumFromInt(22),
        .location = location,
        .size = .{ .cols = 60, .rows = 20 },
        .launch = .{
            .cwd = "/work",
            .cwd_source = .invalid,
            .arguments = &.{"/bin/sh"},
        },
    }));

    const closed = (try schema.decodeClient(try schema.encodeClosePane(&buffer, .{
        .request_id = @enumFromInt(22),
        .pane_id = @enumFromInt(8),
    }))).close_pane;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(8)), closed.pane_id);
}

test "tab lifecycle client messages round trip" {
    var buffer: [4096]u8 = undefined;
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const location: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(3) };

    const requested = (try schema.decodeClient(try schema.encodeRequestWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(40),
        .workspace = workspace,
    }))).request_workspace_snapshot;
    try std.testing.expect(std.meta.eql(workspace, requested.workspace));

    const created = (try schema.decodeClient(try schema.encodeCreateTab(&buffer, .{
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
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(10)), created.launch.cwd_source.?);

    const renamed = (try schema.decodeClient(try schema.encodeRenameTab(&buffer, .{
        .request_id = @enumFromInt(42),
        .location = location,
        .label = "server",
    }))).rename_tab;
    try std.testing.expectEqualStrings("server", renamed.label);

    const closed = (try schema.decodeClient(try schema.encodeCloseTab(&buffer, .{
        .request_id = @enumFromInt(43),
        .location = location,
    }))).close_tab;
    try std.testing.expectEqualDeep(location, closed.location);

    const moved = (try schema.decodeClient(try schema.encodeMoveTab(&buffer, .{
        .request_id = @enumFromInt(44),
        .location = location,
        .direction = .previous,
    }))).move_tab;
    try std.testing.expectEqual(schema.TabMoveDirection.previous, moved.direction);
}

test "tab lifecycle server messages round trip" {
    var buffer: [4096]u8 = undefined;
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const location: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(3) };
    const descriptors = [_]schema.TabDescriptor{
        .{ .tab_id = @enumFromInt(3), .position = 0, .pane_count = 2, .label = "main" },
        .{ .tab_id = @enumFromInt(4), .position = 1, .pane_count = 1, .label = "logs" },
    };

    const snapshot = (try schema.decodeServer(try schema.encodeWorkspaceSnapshot(&buffer, .{
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

    const created = (try schema.decodeServer(try schema.encodeTabCreated(&buffer, .{
        .request_id = @enumFromInt(51),
        .location = location,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(9),
    }))).tab_created;
    try std.testing.expectEqualStrings("logs", created.label);

    const renamed = (try schema.decodeServer(try schema.encodeTabRenamed(&buffer, .{
        .request_id = @enumFromInt(52),
        .location = location,
        .label = "server",
    }))).tab_renamed;
    try std.testing.expectEqualStrings("server", renamed.label);

    const closed = (try schema.decodeServer(try schema.encodeTabClosed(&buffer, .{
        .request_id = @enumFromInt(53),
        .location = location,
        .workspace_closed = false,
    }))).tab_closed;
    try std.testing.expect(!closed.workspace_closed);

    const lifecycle_closed = (try schema.decodeServer(try schema.encodeTabClosed(&buffer, .{
        .request_id = .none,
        .location = location,
        .workspace_closed = true,
    }))).tab_closed;
    try std.testing.expectEqual(schema.RequestId.none, lifecycle_closed.request_id);
    try std.testing.expect(lifecycle_closed.workspace_closed);

    const moved = (try schema.decodeServer(try schema.encodeTabMoved(&buffer, .{
        .request_id = @enumFromInt(54),
        .location = location,
        .position = 0,
    }))).tab_moved;
    try std.testing.expectEqual(@as(u16, 0), moved.position);
}

test "history queries round trip with scopes" {
    var buffer: [2048]u8 = undefined;
    const cwd = (try schema.decodeClient(try schema.encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(31),
        .query = "zig build",
        .scope = .cwd,
        .scope_value = "/work/telar",
        .failed_only = true,
        .limit = 12,
    }))).query_history;
    try std.testing.expectEqualStrings("zig build", cwd.query);
    try std.testing.expectEqual(schema.HistoryScope.cwd, cwd.scope);
    try std.testing.expectEqualStrings("/work/telar", cwd.scope_value);
    try std.testing.expect(cwd.failed_only);
    try std.testing.expectEqual(@as(u16, 12), cwd.limit);

    const pane = (try schema.decodeClient(try schema.encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(32),
        .scope = .pane,
        .pane_id = @enumFromInt(9),
    }))).query_history;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(9)), pane.pane_id);
}

test "fixed server messages round trip" {
    var buffer: [128]u8 = undefined;
    const opened = (try schema.decodeServer(try schema.encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(5),
        .pane_id = @enumFromInt(12),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(4),
        },
        .created = true,
    }))).pane_opened;
    try std.testing.expect(opened.created);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(12)), opened.pane_id);
    try std.testing.expectEqual(
        @as(schema.WorkspaceId, @enumFromInt(2)),
        opened.location.workspace.workspace,
    );
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(4)), opened.location.tab_id);

    const worktree_opened = (try schema.decodeServer(try schema.encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(6),
        .pane_id = @enumFromInt(13),
        .location = .{
            .workspace = .{ .worktree = @enumFromInt(3) },
            .tab_id = @enumFromInt(5),
        },
        .created = false,
    }))).pane_opened;
    try std.testing.expectEqual(
        @as(schema.WorktreeId, @enumFromInt(3)),
        worktree_opened.location.workspace.worktree,
    );

    const exited = (try schema.decodeServer(try schema.encodePaneExited(&buffer, .{
        .pane_id = @enumFromInt(12),
        .kind = .exited,
        .value = 7,
    }))).pane_exited;
    try std.testing.expectEqual(@as(u32, 7), exited.value);

    const failed = (try schema.decodeServer(try schema.encodeRequestFailed(&buffer, .{
        .request_id = @enumFromInt(5),
        .code = .pane_not_found,
        .message = "pane 12 does not exist",
    }))).request_failed;
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, failed.code);
    try std.testing.expectEqualStrings("pane 12 does not exist", failed.message);

    try std.testing.expect((try schema.decodeServer(try schema.encodeRuntimeStopping(&buffer))) == .runtime_stopping);
}

test "tab snapshots preserve ordered pane descriptors" {
    const panes = [_]schema.PaneDescriptor{
        .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        .{ .pane_id = @enumFromInt(9), .lifecycle = .exited },
    };
    var buffer: [128]u8 = undefined;
    const snapshot = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
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
    const entries = [_]schema.HistoryEntry{
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
    const results = (try schema.decodeServer(try schema.encodeHistoryResults(&buffer, .{
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
    const cells = [_]ui.Cell{.{}};
    const spans = [_]frame.Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    const message = frame.Frame{
        .pane_id = @enumFromInt(4),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .input_modes = .{ .kitty_keyboard_flags = 31, .modify_other_keys_2 = true },
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    };

    const decoded = (try schema.decodeServer(try schema.encodePaneFrame(&buffer, message))).pane_frame;
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(4)), decoded.pane_id);
    try std.testing.expectEqualDeep(message.input_modes, decoded.input_modes);
    var span_iterator = decoded.spans();
    var cell_iterator = ((try span_iterator.next()).?).cells();
    try std.testing.expectEqualDeep(cells[0], (try cell_iterator.next()).?);
}

test "pane frames reject unsupported keyboard flags" {
    var buffer: [256]u8 = undefined;
    const payload = try std.fmt.hexToBytes(&buffer, golden.pane_frame);
    // Tag + pane/frame identities + geometry + cursor + mouse + six modes.
    const keyboard_flags_offset = 1 + 24 + 4 + 5 + 3 + 6;
    for ([_]u8{ 32, 64, 128, 255 }) |flags| {
        payload[keyboard_flags_offset] = flags;
        try std.testing.expectError(error.InvalidKeyboardFlags, schema.decodeServer(payload));
    }
}

test "malformed application messages are rejected" {
    try std.testing.expectError(error.UnknownMessage, schema.decodeClient(&.{0xff}));
    try std.testing.expectError(error.Truncated, schema.decodeClient(&.{@intFromEnum(schema.ClientTag.pane_resize)}));

    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidRequestId, schema.encodeOpenPane(&buffer, .{
        .request_id = .none,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{ .cwd = "/tmp", .arguments = &.{"/bin/sh"} },
    }));
    try std.testing.expectError(error.EmbeddedNul, schema.encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{"bad\x00argument"},
        },
    }));
    try std.testing.expectError(error.InvalidPaneId, schema.encodePaneInput(&buffer, .{
        .pane_id = .invalid,
        .bytes = "x",
    }));

    const agent_entry: schema.AgentSnapshotEntry = .{
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
    const duplicate_entries = [_]schema.AgentSnapshotEntry{ agent_entry, agent_entry };
    var agent_buffer: [1024]u8 = undefined;
    try std.testing.expectError(error.DuplicateAgentEntry, schema.encodeAgentSnapshot(
        &agent_buffer,
        .{ .revision = 1, .entries = &duplicate_entries },
    ));

    const single = try schema.encodeAgentSnapshot(
        &agent_buffer,
        .{ .revision = 1, .entries = &.{agent_entry} },
    );
    const entry_offset = 1 + @sizeOf(u64) + @sizeOf(u16);
    const entry_len = single.len - entry_offset;
    @memcpy(agent_buffer[single.len..][0..entry_len], single[entry_offset..]);
    std.mem.writeInt(u16, agent_buffer[1 + @sizeOf(u64) .. entry_offset], 2, .little);
    try std.testing.expectError(
        error.DuplicateAgentEntry,
        schema.decodeServer(agent_buffer[0 .. single.len + entry_len]),
    );
}

test "agent snapshot display fields are bounded and validated before allocation" {
    const workspace = [_]u8{'w'} ** schema.max_agent_workspace_label_bytes;
    const tab = [_]u8{'t'} ** schema.max_tab_label_bytes;
    const title = [_]u8{'s'} ** schema.max_agent_session_title_bytes;
    const cwd = [_]u8{'c'} ** schema.max_agent_cwd_label_bytes;
    var entry: schema.AgentSnapshotEntry = .{
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
    const encoded = try schema.encodeAgentSnapshot(&buffer, .{
        .revision = 1,
        .entries = &.{entry},
    });
    var iterator = (try schema.decodeServer(encoded)).agent_snapshot.entries();
    const decoded = (try iterator.next()).?;
    try std.testing.expectEqualSlices(u8, &workspace, decoded.workspace_label);
    try std.testing.expectEqualSlices(u8, &tab, decoded.tab_label);
    try std.testing.expectEqualSlices(u8, &title, decoded.session_title);
    try std.testing.expectEqualSlices(u8, &cwd, decoded.cwd_label);
    try std.testing.expect((try iterator.next()) == null);

    const workspace_too_long = [_]u8{'x'} ** (schema.max_agent_workspace_label_bytes + 1);
    entry.workspace_label = &workspace_too_long;
    try std.testing.expectError(error.InvalidByteString, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 2, .entries = &.{entry} },
    ));
    entry.workspace_label = &workspace;
    const tab_too_long = [_]u8{'x'} ** (schema.max_tab_label_bytes + 1);
    entry.tab_label = &tab_too_long;
    try std.testing.expectError(error.InvalidByteString, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 3, .entries = &.{entry} },
    ));
    entry.tab_label = &tab;
    const title_too_long = [_]u8{'x'} ** (schema.max_agent_session_title_bytes + 1);
    entry.session_title = &title_too_long;
    try std.testing.expectError(error.InvalidByteString, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 4, .entries = &.{entry} },
    ));
    entry.session_title = &title;
    const cwd_too_long = [_]u8{'x'} ** (schema.max_agent_cwd_label_bytes + 1);
    entry.cwd_label = &cwd_too_long;
    try std.testing.expectError(error.InvalidByteString, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 5, .entries = &.{entry} },
    ));
    entry.cwd_label = &cwd;
    entry.workspace_label = "bad\nlabel";
    try std.testing.expectError(error.InvalidAgentDisplayText, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 6, .entries = &.{entry} },
    ));
    entry.workspace_label = "\xff";
    try std.testing.expectError(error.InvalidUtf8, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 7, .entries = &.{entry} },
    ));
    entry.workspace_label = &workspace;
    entry.title_source = .generated;
    entry.title_state = .pending;
    try std.testing.expectError(error.InvalidAgentTitle, schema.encodeAgentSnapshot(
        &buffer,
        .{ .revision = 8, .entries = &.{entry} },
    ));
}

test "truncated client and server messages are rejected" {
    var client_buffer: [256]u8 = undefined;
    const client_payload = try schema.encodeOpenPane(&client_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{ "/bin/sh", "-l" },
        },
    });
    for (0..client_payload.len) |length| {
        try std.testing.expectError(error.Truncated, schema.decodeClient(client_payload[0..length]));
    }

    var server_buffer: [128]u8 = undefined;
    const server_payload = try schema.encodePaneOpened(&server_buffer, .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(2),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .created = true,
    });
    for (0..server_payload.len) |length| {
        try std.testing.expectError(error.Truncated, schema.decodeServer(server_payload[0..length]));
    }
}

test "client layout schema validates trees focus and chrome-only recovery" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const incomplete = [_]schema.ClientLayoutNode{
        .{ .split = .{ .axis = .horizontal, .ratio = 5000 } },
        .{ .pane = @enumFromInt(5) },
    };
    try std.testing.expectError(error.InvalidClientLayoutTree, schema.encodeClientLayoutUpdate(&buffer, .{
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

    const duplicate = [_]schema.ClientLayoutNode{
        .{ .split = .{ .axis = .vertical, .ratio = 5000 } },
        .{ .pane = @enumFromInt(5) },
        .{ .pane = @enumFromInt(5) },
    };
    try std.testing.expectError(error.DuplicatePane, schema.encodeClientLayoutUpdate(&buffer, .{
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

    const pane = [_]schema.ClientLayoutNode{.{ .pane = @enumFromInt(5) }};
    try std.testing.expectError(error.InvalidClientLayoutFullscreen, schema.encodeClientLayoutUpdate(&buffer, .{
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
    }));

    const chrome_only = try schema.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = false,
        .sidebar_width = 73,
        .workspace_list_collapsed = true,
    });
    const restored = (try schema.decodeServer(chrome_only)).client_layout_snapshot;
    try std.testing.expect(restored.restored);
    try std.testing.expect(!restored.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 73), restored.sidebar_width);
    try std.testing.expect(restored.workspace_list_collapsed);
    try std.testing.expect(restored.active_tab == null);
    try std.testing.expectEqual(@as(u16, 0), restored.tab_count);
}

test "workspace closure handoffs are present only for a different surviving workspace" {
    var buffer: [128]u8 = undefined;
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    try std.testing.expectError(
        error.UnexpectedPreviousWorkspace,
        schema.encodeTabClosed(&buffer, .{
            .request_id = .none,
            .location = location,
            .workspace_closed = false,
            .previous_workspace = @enumFromInt(6),
        }),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceSuccessor,
        schema.encodeTabClosed(&buffer, .{
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

    const cells = try gpa.alloc(ui.Cell, total);
    defer gpa.free(cells);
    for (cells, 0..) |*cell, index| {
        cell.* = .{
            .len = ui.Cell.max_bytes,
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
        @memset(cell.bytes[0..ui.Cell.max_bytes], 'a');
    }

    const spans = try gpa.alloc(frame.Span, span_count);
    defer gpa.free(spans);
    for (spans, 0..) |*span, index| {
        const start: u32 = @intCast(index * per_span);
        span.* = .{ .start = start, .cells = cells[start .. start + per_span] };
    }

    // Larger than any legal frame, so the only possible failure is the budget.
    const buffer = try gpa.alloc(u8, frame.max_body_size + 128 * 1024);
    defer gpa.free(buffer);
    try std.testing.expectError(error.FrameTooLarge, schema.encodePaneFrame(buffer, .{
        .pane_id = try schema.id.pane(7),
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
