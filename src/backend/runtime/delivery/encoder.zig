//! Runtime protocol projection from authoritative state.

const EncodeContext = @import("EncodeContext.zig");
const response_queue = @import("response_queue.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneDescriptorType = @import("telar-core").PaneDescriptor;
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const TabDescriptorType = @import("telar-core").TabDescriptor;
const max_history_results = @import("telar-core").max_history_results;
const HistoryEntryType = @import("telar-core").HistoryEntry;
const max_pane_text_bytes_module = @import("telar-core").max_pane_text_bytes;
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;
const encodePaneOpened_module = @import("telar-core").encodePaneOpened;
const encodeTabSnapshot_module = @import("telar-core").encodeTabSnapshot;
const encodeWorkspaceSnapshot_module = @import("telar-core").encodeWorkspaceSnapshot;
const encodeTabCreated_module = @import("telar-core").encodeTabCreated;
const encodeTabRenamed_module = @import("telar-core").encodeTabRenamed;
const encodeTabClosed_module = @import("telar-core").encodeTabClosed;
const encodeTabMoved_module = @import("telar-core").encodeTabMoved;
const encodeNotification_module = @import("telar-core").encodeNotification;
const encodeNotificationShown_module = @import("telar-core").encodeNotificationShown;
const encodeAgentSound_module = @import("telar-core").encodeAgentSound;
const encodeRequestCompleted_module = @import("telar-core").encodeRequestCompleted;
const encodeHistoryPruned_module = @import("telar-core").encodeHistoryPruned;
const max_history_stats_top_module = @import("telar-core").max_history_stats_top;
const HistoryStatsTopType = @import("telar-core").HistoryStatsTop;
const encodeHistoryStats_module = @import("telar-core").encodeHistoryStats;
const encodeHistoryOutput_module = @import("telar-core").encodeHistoryOutput;
const encodePaneMatches_module = @import("telar-core").encodePaneMatches;
const encodePaneText_module = @import("telar-core").encodePaneText;
const encodePaneFocusCommand_module = @import("telar-core").encodePaneFocusCommand;
const encodePaneFocusResult_module = @import("telar-core").encodePaneFocusResult;
const encodeCommandSuggestion_module = @import("telar-core").encodeCommandSuggestion;
const QueryResultType = @import("../../history/QueryResult.zig");
const std = @import("std");
const encodeHistoryResults_module = @import("telar-core").encodeHistoryResults;
const StateType = @import("../../workspace/State.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const workspace = @import("telar-core").workspace;
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const decodeServer_module = @import("telar-core").decodeServer;
const FailureCodeType = @import("telar-core").FailureCode;
const SuggestionStatusType = @import("telar-core").SuggestionStatus;

/// Encodes one queued response against the *current* stores. A response can
/// outlive what it describes - the workspace of a queued snapshot may close
/// before the send slot frees up - and encoding must then degrade to a
/// `request_failed` reply, never to an error that tears the client down.
///
/// ```zig
/// const payload = try encodeResponse(context, &response);
/// ```
pub fn encodeResponse(context: EncodeContext, response: *response_queue.PendingResponse) ![]const u8 {
    const buffer = context.buffer;
    const panes = context.panes;
    const workspaces = context.workspaces;
    const history_result = context.history_result;
    const history_output = context.history_output;
    const history_stats = context.history_stats;

    var descriptor_storage: [max_panes_per_tab]PaneDescriptorType = undefined;
    var tab_storage: [max_tabs_per_workspace]TabDescriptorType = undefined;
    var history_storage: [max_history_results]HistoryEntryType = undefined;
    var text_storage: [max_pane_text_bytes_module]u8 = undefined;
    return switch (response.*) {
        .request_failed => |failure| try encodeRequestFailed_module(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        }),
        .pane_opened => |opened| try encodePaneOpened_module(buffer, opened),
        .tab_snapshot => |snapshot| try encodeTabSnapshot_module(buffer, .{
            .request_id = snapshot.request_id,
            .location = snapshot.location,
            .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
        }),
        .workspace_snapshot => |snapshot| payload: {
            const descriptor_snapshot = workspaces.descriptors(
                snapshot.workspace,
                &tab_storage,
            ) orelse
                break :payload try encodeRequestFailed_module(buffer, .{
                    .request_id = snapshot.request_id,
                    .code = .workspace_not_found,
                    .message = "workspace closed before its snapshot was sent",
                });
            for (descriptor_snapshot.tabs) |*tab| {
                tab.pane_count = panes.countAt(.{
                    .workspace = snapshot.workspace,
                    .tab_id = tab.tab_id,
                });
            }
            break :payload try encodeWorkspaceSnapshot_module(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .name = descriptor_snapshot.name,
                .tabs = descriptor_snapshot.tabs,
            });
        },
        .tab_created => |*created| try encodeTabCreated_module(buffer, .{
            .request_id = created.request_id,
            .location = created.location,
            .position = created.position,
            .label = created.labelSlice(),
            .root_pane_id = created.root_pane_id,
        }),
        .tab_renamed => |*renamed| try encodeTabRenamed_module(buffer, .{
            .request_id = renamed.request_id,
            .location = renamed.location,
            .label = renamed.labelSlice(),
        }),
        .tab_closed => |closed| try encodeTabClosed_module(buffer, closed),
        .tab_moved => |moved| try encodeTabMoved_module(buffer, moved),
        .notification => |*notification| try encodeNotification_module(
            buffer,
            notification.view(),
        ),
        .notification_shown => |shown| try encodeNotificationShown_module(buffer, shown),
        .agent_sound => |sound| try encodeAgentSound_module(buffer, sound),
        .history_result => |result| payload: {
            history_result.* = result;
            break :payload try encodeHistoryResult(buffer, result, &history_storage);
        },
        .request_completed => |completed| try encodeRequestCompleted_module(buffer, completed),
        .history_pruned => |pruned| try encodeHistoryPruned_module(buffer, pruned),
        .history_stats => |result| payload: {
            history_stats.* = result;
            var top_storage: [max_history_stats_top_module]HistoryStatsTopType = undefined;
            for (result.top, 0..) |entry, index| {
                top_storage[index] = .{ .count = entry.count, .command = entry.command };
            }
            break :payload try encodeHistoryStats_module(buffer, .{
                .request_id = result.request_id,
                .total = result.total,
                .unique = result.unique,
                .top = top_storage[0..result.top.len],
            });
        },
        .history_output => |result| payload: {
            history_output.* = result;
            break :payload try encodeHistoryOutput_module(buffer, .{
                .request_id = result.request_id,
                .id = result.id,
                .truncated = result.truncated,
                .observed_bytes = result.observed_bytes,
                .content = result.content,
            });
        },
        .pane_matches => |*found| try encodePaneMatches_module(buffer, .{
            .request_id = found.request_id,
            .pane_id = found.pane_id,
            .truncated = found.matches.truncated,
            .matches = found.matches.slice(),
        }),
        .pane_text => |*read| payload: {
            const target = panes.resolveControlConst(read.pane) orelse
                break :payload try encodeRequestFailed_module(buffer, .{
                    .request_id = read.request_id,
                    .code = .pane_not_found,
                    .message = "pane closed before its text was read",
                });
            const dump = target.dumpText(.{ .rows = read.rows, .source = read.source }, &text_storage);
            break :payload try encodePaneText_module(buffer, .{
                .request_id = read.request_id,
                .pane_id = read.pane.id,
                .truncated = dump.truncated,
                .text = text_storage[0..dump.len],
            });
        },
        .pane_focus_command => |command| try encodePaneFocusCommand_module(buffer, command),
        .pane_focus_result => |result| try encodePaneFocusResult_module(buffer, result),
        .command_suggestion => |*suggested| try encodeCommandSuggestion_module(buffer, .{
            .request_id = suggested.request_id,
            .status = suggested.status,
            .text = suggested.textSlice(),
        }),
    };
}

fn encodeHistoryResult(buffer: []u8, result: *const QueryResultType, storage: *[max_history_results]HistoryEntryType) ![]const u8 {
    std.debug.assert(result.entries.len <= storage.len);
    for (result.entries, 0..) |entry, index| {
        storage[index] = .{
            .id = entry.id,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = switch (entry.status) {
                .completed => .completed,
                .interrupted => .interrupted,
                .running => .running,
            },
            .author = entry.author,
            .origin = entry.origin,
            .provider = entry.provider,
            .command = entry.command,
            .command_truncated = entry.command_truncated,
            .cwd = entry.cwd,
            .workspace_path = entry.workspace_path,
        };
    }
    return encodeHistoryResults_module(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
        .snapshot_id = result.snapshot_id,
        .has_more = result.has_more,
    });
}

test "a workspace snapshot for a vanished workspace becomes a failure reply" {
    var workspaces: StateType = .{};
    var panes: PaneStore = .{};
    var response: response_queue.PendingResponse = .{ .workspace_snapshot = .{
        .request_id = @enumFromInt(9),
        .workspace = .{ .workspace = try workspace(77) },
    } };
    var buffer: [1024]u8 = undefined;
    var history_result: ?*QueryResultType = null;
    var history_output: ?*OutputResultType = null;
    var history_stats: ?*StatsResultType = null;

    const payload = try encodeResponse(.{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = ReaderType.init(&workspaces),
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    }, &response);
    const decoded = try decodeServer_module(payload);

    try std.testing.expect(decoded == .request_failed);
    try std.testing.expectEqual(FailureCodeType.workspace_not_found, decoded.request_failed.code);
}

test "a command suggestion encodes its owned text and a bare status" {
    var workspaces: StateType = .{};
    var panes: PaneStore = .{};
    var buffer: [2048]u8 = undefined;
    var history_result: ?*QueryResultType = null;
    var history_output: ?*OutputResultType = null;
    var history_stats: ?*StatsResultType = null;
    const context: EncodeContext = .{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = ReaderType.init(&workspaces),
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    };

    var ready: response_queue.PendingResponse = .{ .command_suggestion = .{ .request_id = @enumFromInt(41), .status = .ready } };
    @memcpy(ready.command_suggestion.text[0..6], "ls -lS");
    ready.command_suggestion.text_len = 6;
    const decoded = try decodeServer_module(try encodeResponse(context, &ready));
    try std.testing.expect(decoded == .command_suggestion);
    try std.testing.expectEqual(SuggestionStatusType.ready, decoded.command_suggestion.status);
    try std.testing.expectEqualStrings("ls -lS", decoded.command_suggestion.text);

    var timed_out: response_queue.PendingResponse = .{ .command_suggestion = .{ .request_id = @enumFromInt(42), .status = .timeout } };
    const bare = try decodeServer_module(try encodeResponse(context, &timed_out));
    try std.testing.expectEqual(SuggestionStatusType.timeout, bare.command_suggestion.status);
    try std.testing.expectEqual(@as(usize, 0), bare.command_suggestion.text.len);
}
