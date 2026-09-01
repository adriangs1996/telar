//! Runtime protocol projection from authoritative state.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace = @import("../../workspace/root.zig");
const response_queue = @import("response_queue.zig");

const schema = core.schema;
const PaneStore = pane_mod.PaneStore;
const PendingResponse = response_queue.PendingResponse;
const max_panes = pane_mod.max_panes;
const max_tabs_per_workspace = workspace.max_tabs_per_workspace;

pub const EncodeContext = struct {
    buffer: []u8,
    panes: *const PaneStore,
    workspaces: workspace.Reader,
    history_result: *?*history.model.QueryResult,
};

/// Encodes one queued response against the *current* stores. A response can
/// outlive what it describes - the workspace of a queued snapshot may close
/// before the send slot frees up - and encoding must then degrade to a
/// `request_failed` reply, never to an error that tears the client down.
///
/// ```zig
/// const payload = try encodeResponse(context, &response);
/// ```
pub fn encodeResponse(context: EncodeContext, response: *PendingResponse) ![]const u8 {
    const buffer = context.buffer;
    const panes = context.panes;
    const workspaces = context.workspaces;
    const history_result = context.history_result;

    var descriptor_storage: [max_panes]schema.PaneDescriptor = undefined;
    var tab_storage: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    var history_storage: [history.model.max_results]schema.HistoryEntry = undefined;
    var text_storage: [schema.max_pane_text_bytes]u8 = undefined;
    return switch (response.*) {
        .request_failed => |failure| try schema.encodeRequestFailed(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        }),
        .pane_opened => |opened| try schema.encodePaneOpened(buffer, opened),
        .tab_snapshot => |snapshot| try schema.encodeTabSnapshot(buffer, .{
            .request_id = snapshot.request_id,
            .location = snapshot.location,
            .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
        }),
        .workspace_snapshot => |snapshot| payload: {
            const descriptor_snapshot = workspaces.descriptors(
                snapshot.workspace,
                &tab_storage,
            ) orelse
                break :payload try schema.encodeRequestFailed(buffer, .{
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
            break :payload try schema.encodeWorkspaceSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .name = descriptor_snapshot.name,
                .tabs = descriptor_snapshot.tabs,
            });
        },
        .tab_created => |*created| try schema.encodeTabCreated(buffer, .{
            .request_id = created.request_id,
            .location = created.location,
            .position = created.position,
            .label = created.labelSlice(),
            .root_pane_id = created.root_pane_id,
        }),
        .tab_renamed => |*renamed| try schema.encodeTabRenamed(buffer, .{
            .request_id = renamed.request_id,
            .location = renamed.location,
            .label = renamed.labelSlice(),
        }),
        .tab_closed => |closed| try schema.encodeTabClosed(buffer, closed),
        .tab_moved => |moved| try schema.encodeTabMoved(buffer, moved),
        .notification => |*notification| try schema.encodeNotification(
            buffer,
            notification.view(),
        ),
        .notification_shown => |shown| try schema.encodeNotificationShown(buffer, shown),
        .agent_sound => |sound| try schema.encodeAgentSound(buffer, sound),
        .history_result => |result| payload: {
            history_result.* = result;
            break :payload try encodeHistoryResult(buffer, result, &history_storage);
        },
        .request_completed => |completed| try schema.encodeRequestCompleted(buffer, completed),
        .pane_text => |*read| payload: {
            const target = panes.resolveConst(read.pane) orelse
                break :payload try schema.encodeRequestFailed(buffer, .{
                    .request_id = read.request_id,
                    .code = .pane_not_found,
                    .message = "pane closed before its text was read",
                });
            const dump = target.dumpText(.{ .rows = read.rows, .source = read.source }, &text_storage);
            break :payload try schema.encodePaneText(buffer, .{
                .request_id = read.request_id,
                .pane_id = read.pane.id,
                .truncated = dump.truncated,
                .text = text_storage[0..dump.len],
            });
        },
    };
}

fn encodeHistoryResult(buffer: []u8, result: *const history.model.QueryResult, storage: *[history.model.max_results]schema.HistoryEntry) ![]const u8 {
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
            },
            .command = entry.command,
            .cwd = entry.cwd,
            .workspace_path = entry.workspace_path,
        };
    }
    return schema.encodeHistoryResults(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
    });
}

test "a workspace snapshot for a vanished workspace becomes a failure reply" {
    var workspaces: workspace.State = .{};
    var panes: PaneStore = .{};
    var response: PendingResponse = .{ .workspace_snapshot = .{
        .request_id = @enumFromInt(9),
        .workspace = .{ .workspace = try schema.id.workspace(77) },
    } };
    var buffer: [1024]u8 = undefined;
    var history_result: ?*history.model.QueryResult = null;

    const payload = try encodeResponse(.{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = workspace.Reader.init(&workspaces),
        .history_result = &history_result,
    }, &response);
    const decoded = try schema.decodeServer(payload);

    try std.testing.expect(decoded == .request_failed);
    try std.testing.expectEqual(schema.FailureCode.workspace_not_found, decoded.request_failed.code);
}
