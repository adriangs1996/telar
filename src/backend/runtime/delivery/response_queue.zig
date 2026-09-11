//! Bounded, priority-aware responses awaiting one client session's writer.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane = @import("../../pane/root.zig");
const search_commands = @import("../application/commands/search_pane.zig");

pub const schema = core.schema;
pub const capacity = pane.max_panes * 2;

pub const PendingFailure = @import("PendingFailure.zig");

pub const PendingSuggestion = @import("PendingSuggestion.zig");

pub const PendingTabSnapshot = @import("PendingTabSnapshot.zig");

pub const PendingWorkspaceSnapshot = @import("PendingWorkspaceSnapshot.zig");

pub const PendingTabCreated = @import("PendingTabCreated.zig");

pub const PendingTabRenamed = @import("PendingTabRenamed.zig");

pub const PendingNotification = @import("PendingNotification.zig");

pub const PendingPaneText = @import("PendingPaneText.zig");

pub const PendingPaneMatches = @import("PendingPaneMatches.zig");

pub const PendingResponse = union(enum) {
    pane_opened: schema.PaneOpened,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: schema.TabClosed,
    tab_moved: schema.TabMoved,
    notification: PendingNotification,
    notification_shown: schema.NotificationShown,
    agent_sound: schema.AgentSoundNotification,
    history_result: *history.model.QueryResult,
    request_completed: schema.RequestCompleted,
    pane_text: PendingPaneText,
    pane_matches: PendingPaneMatches,
    history_pruned: schema.HistoryPruned,
    history_output: *history.model.OutputResult,
    history_stats: *history.model.StatsResult,
    pane_focus_command: schema.PaneFocusCommand,
    pane_focus_result: schema.PaneFocusResult,
    command_suggestion: PendingSuggestion,
};

pub const ResponseQueue = @import("ResponseQueue.zig");

test "management responses overtake observation work" {
    var queue: ResponseQueue = .{};
    const fake_history: *history.model.QueryResult =
        @ptrFromInt(@alignOf(history.model.QueryResult));
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
    const location: schema.TabLocation = .{
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
        @as(schema.WorkspaceId, @enumFromInt(6)),
        queue.resync_previous_workspace.?,
    );
    queue.len = 0;
}

test "a dropped tab move preserves the workspace that must be resynchronized" {
    var queue: ResponseQueue = .{};
    const location: schema.TabLocation = .{
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
    const request_id: schema.RequestId = @enumFromInt(7);
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
