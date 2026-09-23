//! Runtime protocol projection from authoritative state.
const core = @import("telar-core");

const ReviewResult = @import("../../change_review/Result.zig");
const response_queue = @import("response_queue.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const std = @import("std");
const PaneStore = @import("../../pane/PaneStore.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const OwnedAgentHistoryPage = @import("OwnedAgentHistoryPage.zig");

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

    var descriptor_storage: [core.max_panes_per_tab]core.PaneDescriptor = undefined;
    var tab_storage: [core.max_tabs_per_workspace]core.TabDescriptor = undefined;
    var foreground_storage: [core.max_panes_per_tab]core.PaneForeground = undefined;
    var history_storage: [core.max_history_results]core.HistoryEntry = undefined;
    var text_storage: [core.max_pane_text_bytes]u8 = undefined;
    return switch (response.*) {
        .request_failed => |failure| try core.encodeRequestFailed(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        }),
        .pane_opened => |opened| try core.encodePaneOpened(buffer, opened),
        .tab_snapshot => |snapshot| try core.encodeTabSnapshot(buffer, .{
            .request_id = snapshot.request_id,
            .location = snapshot.location,
            .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
        }),
        .workspace_snapshot => |snapshot| payload: {
            const descriptor_snapshot = workspaces.descriptors(
                snapshot.workspace,
                &tab_storage,
            ) orelse
                break :payload try core.encodeRequestFailed(buffer, .{
                    .request_id = snapshot.request_id,
                    .code = .workspace_not_found,
                    .message = "workspace closed before its snapshot was sent",
                });
            var foreground_count: usize = 0;
            for (descriptor_snapshot.tabs) |*tab| {
                const descriptors = panes.descriptorsAt(.{
                    .workspace = snapshot.workspace,
                    .tab_id = tab.tab_id,
                }, &descriptor_storage);
                tab.pane_count = @intCast(descriptors.len);
                const start = foreground_count;
                for (descriptors) |descriptor| {
                    const pane = panes.resolveControlConst(.{ .id = descriptor.pane_id, .generation = 0 }).?;
                    const name = pane.agent_process_cache.name();
                    foreground_storage[foreground_count] = .{
                        .pane_id = pane.id,
                        .name = if (name.len == 0) "shell" else name,
                    };
                    foreground_count += 1;
                }

                tab.foregrounds = foreground_storage[start..foreground_count];
            }
            break :payload try core.encodeWorkspaceSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .name = descriptor_snapshot.name,
                .tabs = descriptor_snapshot.tabs,
            });
        },
        .tab_created => |*created| try core.encodeTabCreated(buffer, .{
            .request_id = created.request_id,
            .location = created.location,
            .position = created.position,
            .label = created.labelSlice(),
            .root_pane_id = created.root_pane_id,
            .kind = created.kind,
            .pane_generation = created.pane_generation,
        }),
        .tab_renamed => |*renamed| try core.encodeTabRenamed(buffer, .{
            .request_id = renamed.request_id,
            .location = renamed.location,
            .label = renamed.labelSlice(),
        }),
        .tab_closed => |closed| try core.encodeTabClosed(buffer, closed),
        .tab_moved => |moved| try core.encodeTabMoved(buffer, moved),
        .notification => |*notification| try core.encodeNotification(
            buffer,
            notification.view(),
        ),
        .notification_shown => |shown| try core.encodeNotificationShown(buffer, shown),
        .agent_sound => |sound| try core.encodeAgentSound(buffer, sound),
        .change_review => |result| payload: {
            if (context.change_review) |owned| {
                owned.* = result;
            }
            if (result.len > buffer.len) {
                return error.NoSpaceLeft;
            }
            @memcpy(buffer[0..result.len], result.bytes[0..result.len]);
            break :payload buffer[0..result.len];
        },
        .agent_history_page => |result| payload: {
            if (context.agent_history) |owned| {
                owned.* = result;
            }

            const page = result.value;
            if (panes.resolveControlConst(.{ .id = page.snapshot.pane_id, .generation = page.snapshot.pane_generation }) == null) {
                break :payload try core.encodeRequestFailed(buffer, .{
                    .request_id = page.request_id,
                    .code = .pane_not_found,
                    .message = "agent pane closed before its history was sent",
                });
            }

            break :payload try core.encodeAgentHistoryPage(buffer, page);
        },
        .history_result => |result| payload: {
            history_result.* = result;
            break :payload try encodeHistoryResult(buffer, result, &history_storage);
        },
        .request_completed => |completed| try core.encodeRequestCompleted(buffer, completed),
        .history_pruned => |pruned| try core.encodeHistoryPruned(buffer, pruned),
        .history_stats => |result| payload: {
            history_stats.* = result;
            var top_storage: [core.max_history_stats_top]core.HistoryStatsTop = undefined;
            for (result.top, 0..) |entry, index| {
                top_storage[index] = .{ .count = entry.count, .command = entry.command };
            }
            break :payload try core.encodeHistoryStats(buffer, .{
                .request_id = result.request_id,
                .total = result.total,
                .unique = result.unique,
                .top = top_storage[0..result.top.len],
            });
        },
        .history_output => |result| payload: {
            history_output.* = result;
            break :payload try core.encodeHistoryOutput(buffer, .{
                .request_id = result.request_id,
                .id = result.id,
                .truncated = result.truncated,
                .observed_bytes = result.observed_bytes,
                .content = result.content,
            });
        },
        .pane_matches => |*found| try core.encodePaneMatches(buffer, .{
            .request_id = found.request_id,
            .pane_id = found.pane_id,
            .truncated = found.matches.truncated,
            .matches = found.matches.slice(),
        }),
        .pane_text => |*read| payload: {
            const target = panes.resolveControlConst(read.pane) orelse
                break :payload try core.encodeRequestFailed(buffer, .{
                    .request_id = read.request_id,
                    .code = .pane_not_found,
                    .message = "pane closed before its text was read",
                });
            const dump = target.dumpText(.{ .rows = read.rows, .source = read.source }, &text_storage);
            break :payload try core.encodePaneText(buffer, .{
                .request_id = read.request_id,
                .pane_id = read.pane.id,
                .truncated = dump.truncated,
                .text = text_storage[0..dump.len],
            });
        },
        .client_command => |command| try core.encodeClientCommand(buffer, command),
        .client_command_result => |command| try core.encodeClientCommandResult(buffer, command),
        .client_list => |list| try core.encodeClientList(buffer, list),
        .pane_focus_command => |command| try core.encodePaneFocusCommand(buffer, command),
        .editor_opened => |result| try core.encodeEditorOpened(buffer, result),
        .pane_focus_result => |result| try core.encodePaneFocusResult(buffer, result),
        .command_suggestion => |*suggested| try core.encodeCommandSuggestion(buffer, .{
            .request_id = suggested.request_id,
            .status = suggested.status,
            .text = suggested.textSlice(),
        }),
    };
}

fn encodeHistoryResult(buffer: []u8, result: *const QueryResult, storage: *[core.max_history_results]core.HistoryEntry) ![]const u8 {
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
    return core.encodeHistoryResults(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
        .snapshot_id = result.snapshot_id,
        .has_more = result.has_more,
    });
}

test "a workspace snapshot for a vanished workspace becomes a failure reply" {
    var workspaces: Workspaces = .{};
    var panes: PaneStore = .{};
    var response: response_queue.PendingResponse = .{ .workspace_snapshot = .{
        .request_id = @enumFromInt(9),
        .workspace = .{ .workspace = try core.workspace(77) },
    } };
    var buffer: [1024]u8 = undefined;
    var history_result: ?*QueryResult = null;
    var history_output: ?*OutputResult = null;
    var history_stats: ?*StatsResult = null;

    const payload = try encodeResponse(.{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = &workspaces,
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    }, &response);
    const decoded = try core.decodeServer(payload);

    try std.testing.expect(decoded == .request_failed);
    try std.testing.expectEqual(core.FailureCode.workspace_not_found, decoded.request_failed.code);
}

test "a command suggestion encodes its owned text and a bare status" {
    var workspaces: Workspaces = .{};
    var panes: PaneStore = .{};
    var buffer: [2048]u8 = undefined;
    var history_result: ?*QueryResult = null;
    var history_output: ?*OutputResult = null;
    var history_stats: ?*StatsResult = null;
    const context: EncodeContext = .{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = &workspaces,
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    };

    var ready: response_queue.PendingResponse = .{ .command_suggestion = .{ .request_id = @enumFromInt(41), .status = .ready } };
    @memcpy(ready.command_suggestion.text[0..6], "ls -lS");
    ready.command_suggestion.text_len = 6;
    const decoded = try core.decodeServer(try encodeResponse(context, &ready));
    try std.testing.expect(decoded == .command_suggestion);
    try std.testing.expectEqual(core.SuggestionStatus.ready, decoded.command_suggestion.status);
    try std.testing.expectEqualStrings("ls -lS", decoded.command_suggestion.text);

    var timed_out: response_queue.PendingResponse = .{ .command_suggestion = .{ .request_id = @enumFromInt(42), .status = .timeout } };
    const bare = try core.decodeServer(try encodeResponse(context, &timed_out));
    try std.testing.expectEqual(core.SuggestionStatus.timeout, bare.command_suggestion.status);
    try std.testing.expectEqual(@as(usize, 0), bare.command_suggestion.text.len);
}

const EncodeContext = struct {
    buffer: []u8,
    panes: *const PaneStore,
    workspaces: *const Workspaces,
    history_result: *?*QueryResult,
    history_output: *?*OutputResult,
    history_stats: *?*StatsResult,
    agent_history: ?*?*OwnedAgentHistoryPage = null,

    change_review: ?*?*ReviewResult = null,
};
