//! Bounded, priority-aware responses awaiting one client session's writer.

const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneOpenedType = @import("telar-core").PaneOpened;
const PendingFailure = @import("PendingFailure.zig");
const PendingTabSnapshot = @import("PendingTabSnapshot.zig");
const PendingWorkspaceSnapshot = @import("PendingWorkspaceSnapshot.zig");
const PendingTabCreated = @import("PendingTabCreated.zig");
const PendingTabRenamed = @import("PendingTabRenamed.zig");
const TabClosedType = @import("telar-core").TabClosed;
const TabMovedType = @import("telar-core").TabMoved;
const PendingNotification = @import("PendingNotification.zig");
const NotificationShownType = @import("telar-core").NotificationShown;
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
const QueryResultType = @import("../../history/QueryResult.zig");
const RequestCompletedType = @import("telar-core").RequestCompleted;
const PendingPaneText = @import("PendingPaneText.zig");
const PendingPaneMatches = @import("PendingPaneMatches.zig");
const HistoryPrunedType = @import("telar-core").HistoryPruned;
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const PaneFocusCommandType = @import("telar-core").PaneFocusCommand;
const PaneFocusResultType = @import("telar-core").PaneFocusResult;
const PendingSuggestion = @import("PendingSuggestion.zig");
const ResponseQueue = @import("ResponseQueue.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const RequestIdType = @import("telar-core").RequestId;

pub const capacity = max_panes_per_tab * 2;

pub const PendingResponse = union(enum) {
    pane_opened: PaneOpenedType,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: TabClosedType,
    tab_moved: TabMovedType,
    notification: PendingNotification,
    notification_shown: NotificationShownType,
    agent_sound: AgentSoundNotificationType,
    history_result: *QueryResultType,
    request_completed: RequestCompletedType,
    pane_text: PendingPaneText,
    pane_matches: PendingPaneMatches,
    history_pruned: HistoryPrunedType,
    history_output: *OutputResultType,
    history_stats: *StatsResultType,
    pane_focus_command: PaneFocusCommandType,
    pane_focus_result: PaneFocusResultType,
    command_suggestion: PendingSuggestion,
};

test "management responses overtake observation work" {
    var queue: ResponseQueue = .{};
    const fake_history: *QueryResultType =
        @ptrFromInt(@alignOf(QueryResultType));
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
    const location: TabLocationType = .{
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
        @as(WorkspaceIdType, @enumFromInt(6)),
        queue.resync_previous_workspace.?,
    );
    queue.len = 0;
}

test "a dropped tab move preserves the workspace that must be resynchronized" {
    var queue: ResponseQueue = .{};
    const location: TabLocationType = .{
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
    const request_id: RequestIdType = @enumFromInt(7);
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
