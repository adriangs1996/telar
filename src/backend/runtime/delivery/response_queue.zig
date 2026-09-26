//! Bounded, priority-aware responses awaiting one client session's writer.
const core = @import("telar-core");

const ReviewResult = @import("../../change_review/Result.zig");
const PendingFailure = @import("PendingFailure.zig");
const PendingTabCreated = @import("PendingTabCreated.zig");
const PendingTabRenamed = @import("PendingTabRenamed.zig");
const PendingNotification = @import("PendingNotification.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const PathQuery = @import("../../paths/PathQuery.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Matches = @import("Matches.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const PendingSuggestion = @import("PendingSuggestion.zig");
const ResponseQueue = @import("ResponseQueue.zig");
const std = @import("std");

pub const capacity = core.max_panes_per_tab * 2;

pub const PendingResponse = union(enum) {
    client_command: core.ClientCommand,
    client_command_result: core.ClientCommand,
    client_list: core.ClientList,
    editor_opened: core.EditorOpened,
    pane_opened: core.PaneOpened,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: core.TabClosed,
    tab_moved: core.TabMoved,
    notification: PendingNotification,
    notification_shown: core.NotificationShown,
    agent_sound: core.AgentSoundNotification,
    history_result: *QueryResult,
    change_review: *ReviewResult,
    request_completed: core.RequestCompleted,
    pane_text: PendingPaneText,
    pane_matches: PendingPaneMatches,
    history_pruned: core.HistoryPruned,
    history_output: *OutputResult,
    history_stats: *StatsResult,
    pane_focus_command: core.PaneFocusCommand,
    pane_focus_result: core.PaneFocusResult,
    command_suggestion: PendingSuggestion,
    path_results: *PathQuery,
};

test "management responses overtake observation work" {
    var queue: ResponseQueue = .{};
    const fake_history: *QueryResult =
        @ptrFromInt(@alignOf(QueryResult));
    try queue.push(.{ .history_result = fake_history });
    try queue.push(.{ .request_failed = .{
        .request_id = @enumFromInt(2),
        .code = .invalid_request,
        .message = "invalid",
    } });

    try std.testing.expectEqual(@as(u8, 1), queue.peekManagement().?.offset);
    try std.testing.expectEqual(@as(u8, 0), queue.peekObservation().?.offset);
    // The fake pointer only tests ordering and must not reach `clear`.
    queue.len = 0;
}

test "queue records lifetime high water" {
    var queue: ResponseQueue = .{};
    try queue.push(.{ .request_failed = .{
        .request_id = @enumFromInt(1),
        .code = .internal,
        .message = "first",
    } });
    try queue.push(.{ .request_failed = .{
        .request_id = @enumFromInt(2),
        .code = .internal,
        .message = "second",
    } });
    queue.pop();
    try std.testing.expectEqual(@as(u8, 2), queue.high_water);
    queue.clear();
    try std.testing.expectEqual(@as(u8, 2), queue.high_water);
}

test "a dropped workspace close preserves its handoff target" {
    var queue: ResponseQueue = .{};
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    while (queue.len < queue.items.len) try queue.push(.{ .tab_moved = .{
        .request_id = .none,
        .location = location,
        .position = 0,
    } });
    queue.pushOrDrop(.{ .tab_closed = .{
        .request_id = .none,
        .location = location,
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(6),
    } });

    try std.testing.expectEqualDeep(location.workspace, queue.resync_workspace.?);
    try std.testing.expectEqual(
        @as(core.WorkspaceId, @enumFromInt(6)),
        queue.resync_previous_workspace.?,
    );
    queue.len = 0;
}

test "a dropped tab move preserves the workspace that must be resynchronized" {
    var queue: ResponseQueue = .{};
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };

    while (queue.len < queue.items.len) {
        try queue.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    queue.pushOrDrop(.{ .tab_moved = .{
        .request_id = .none,
        .location = location,
        .position = 1,
    } });

    try std.testing.expectEqual(@as(u64, 1), queue.dropped);
    try std.testing.expectEqual(@as(u8, queue.items.len), queue.len);
    try std.testing.expectEqualDeep(location.workspace, queue.resync_workspace.?);
    try std.testing.expect(queue.resync_previous_workspace == null);
    queue.len = 0;
}

test "notification reservations remain exact when request IDs repeat" {
    var queue: ResponseQueue = .{};
    const request_id: core.RequestId = @enumFromInt(7);
    for (0..queue.items.len - 1) |_| {
        try queue.push(.{ .notification_shown = .{
            .request_id = .none,
            .delivered_clients = 0,
        } });
        queue.pop();
    }
    const first = try queue.reserveNotificationShown(request_id);
    const second = try queue.reserveNotificationShown(request_id);

    second.delivered_clients = 3;

    try std.testing.expectEqual(@as(u8, 0), first.delivered_clients);
    try std.testing.expectEqual(@as(u8, 3), second.delivered_clients);
    try std.testing.expectEqual(@as(u8, 2), queue.len);
}

test "notification backpressure is counted and never overwrites queued work" {
    var queue: ResponseQueue = .{};
    while (queue.len < queue.items.len) {
        try queue.push(.{ .notification_shown = .{
            .request_id = @enumFromInt(queue.len + 1),
            .delivered_clients = 0,
        } });
    }
    const pending = PendingNotification.init(.{ .title = "ignored" });

    try std.testing.expect(!queue.pushNotification(pending));

    try std.testing.expectEqual(@as(u8, queue.items.len), queue.len);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped);
}

const PendingPaneMatches = struct {
    /// Search matches are small and computed at request time, so the reply owns
    /// its copy.
    request_id: core.RequestId,
    pane_id: core.PaneId,
    matches: Matches,
};

const PendingTabSnapshot = struct {
    request_id: core.RequestId,
    location: core.TabLocation,
};

const PendingPaneText = struct {
    /// Late-bound text read. The pane resolves at encode time so a queued read
    /// cannot borrow storage from a pane that exits before its send slot frees.
    request_id: core.RequestId,
    pane: PaneKey,
    rows: u16,
    source: core.PaneTextSource,
};

const PendingWorkspaceSnapshot = struct {
    request_id: core.RequestId,
    workspace: core.WorkspaceLocation,
};
