//! Bounded, priority-aware responses awaiting one client session's writer.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../history/root.zig");
const pane = @import("../pane/root.zig");

const schema = core.schema;
const capacity = pane.max_panes * 2;

pub const PendingFailure = struct {
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
};

pub const PendingTabSnapshot = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
};

pub const PendingWorkspaceSnapshot = struct {
    request_id: schema.RequestId,
    workspace: schema.WorkspaceLocation,
};

pub const PendingTabCreated = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    position: u16,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,
    root_pane_id: schema.PaneId,

    pub fn labelSlice(created: *const PendingTabCreated) []const u8 {
        return created.label[0..created.label_len];
    }
};

pub const PendingTabRenamed = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,

    pub fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
        return renamed.label[0..renamed.label_len];
    }
};

pub const PendingNotification = struct {
    level: schema.NotificationLevel,
    duration_ms: u32,
    target: schema.NotificationTarget,
    title_bytes: [schema.max_notification_title_bytes]u8 = undefined,
    title_len: u8,
    message_bytes: [schema.max_notification_message_bytes]u8 = undefined,
    message_len: u8,

    pub fn init(notification: schema.Notification) PendingNotification {
        std.debug.assert(notification.title.len <= schema.max_notification_title_bytes);
        std.debug.assert(notification.message.len <= schema.max_notification_message_bytes);
        var pending: PendingNotification = .{
            .level = notification.level,
            .duration_ms = notification.duration_ms,
            .target = notification.target,
            .title_len = @intCast(notification.title.len),
            .message_len = @intCast(notification.message.len),
        };
        @memcpy(pending.title_bytes[0..notification.title.len], notification.title);
        @memcpy(pending.message_bytes[0..notification.message.len], notification.message);
        return pending;
    }

    pub fn view(notification: *const PendingNotification) schema.Notification {
        return .{
            .level = notification.level,
            .duration_ms = notification.duration_ms,
            .target = notification.target,
            .title = notification.title_bytes[0..notification.title_len],
            .message = notification.message_bytes[0..notification.message_len],
        };
    }
};

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
};

pub const ResponseQueue = struct {
    items: [capacity]PendingResponse = undefined,
    head: u8 = 0,
    len: u8 = 0,
    dropped: u64 = 0,
    resync_workspace: ?schema.WorkspaceLocation = null,
    resync_previous_workspace: ?schema.WorkspaceId = null,

    pub const Entry = struct {
        offset: u8,
        response: *PendingResponse,
    };

    pub fn push(queue: *ResponseQueue, response: PendingResponse) !void {
        if (queue.len == queue.items.len) return error.ResponseQueueFull;
        const index = (@as(usize, queue.head) + queue.len) % queue.items.len;
        queue.items[index] = response;
        queue.len += 1;
    }

    /// Observation notifications may be dropped under backpressure. State
    /// notifications record the workspace that must be resynchronized.
    pub fn pushOrDrop(queue: *ResponseQueue, response: PendingResponse) void {
        queue.push(response) catch {
            switch (response) {
                .history_result => |result| result.deinit(),
                .tab_closed => |closed| {
                    queue.resync_workspace = closed.location.workspace;
                    queue.resync_previous_workspace = closed.previous_workspace;
                },
                .tab_moved => |moved| {
                    queue.resync_workspace = moved.location.workspace;
                    queue.resync_previous_workspace = null;
                },
                else => {},
            }
            queue.dropped += 1;
        };
    }

    pub fn pushNotification(queue: *ResponseQueue, notification: PendingNotification) bool {
        queue.push(.{ .notification = notification }) catch {
            queue.dropped += 1;
            return false;
        };
        return true;
    }

    pub fn pushAgentSound(queue: *ResponseQueue, sound: schema.AgentSoundNotification) bool {
        queue.push(.{ .agent_sound = sound }) catch {
            queue.dropped += 1;
            return false;
        };
        return true;
    }

    pub fn setNotificationDelivery(
        queue: *ResponseQueue,
        request_id: schema.RequestId,
        delivered_clients: u8,
    ) void {
        for (0..queue.len) |offset| {
            const index = (@as(usize, queue.head) + offset) % queue.items.len;
            switch (queue.items[index]) {
                .notification_shown => |*shown| if (shown.request_id == request_id) {
                    shown.delivered_clients = delivered_clients;
                    return;
                },
                else => {},
            }
        }
        unreachable;
    }

    pub fn peek(queue: *ResponseQueue) ?*PendingResponse {
        if (queue.len == 0) return null;
        return &queue.items[queue.head];
    }

    pub fn peekManagement(queue: *ResponseQueue) ?Entry {
        for (0..queue.len) |offset| {
            const index = (@as(usize, queue.head) + offset) % queue.items.len;
            if (queue.items[index] == .history_result) continue;
            return .{ .offset = @intCast(offset), .response = &queue.items[index] };
        }
        return null;
    }

    pub fn peekObservation(queue: *ResponseQueue) ?Entry {
        for (0..queue.len) |offset| {
            const index = (@as(usize, queue.head) + offset) % queue.items.len;
            if (queue.items[index] != .history_result) continue;
            return .{ .offset = @intCast(offset), .response = &queue.items[index] };
        }
        return null;
    }

    pub fn pop(queue: *ResponseQueue) void {
        std.debug.assert(queue.len != 0);
        queue.head = @intCast((@as(usize, queue.head) + 1) % queue.items.len);
        queue.len -= 1;
    }

    pub fn removeAt(queue: *ResponseQueue, offset: u8) void {
        std.debug.assert(offset < queue.len);
        var cursor: usize = offset;
        while (cursor + 1 < queue.len) : (cursor += 1) {
            const destination = (@as(usize, queue.head) + cursor) % queue.items.len;
            const source = (@as(usize, queue.head) + cursor + 1) % queue.items.len;
            queue.items[destination] = queue.items[source];
        }
        queue.len -= 1;
    }

    pub fn clear(queue: *ResponseQueue) void {
        while (queue.peek()) |response| {
            switch (response.*) {
                .history_result => |result| result.deinit(),
                else => {},
            }
            queue.pop();
        }
        queue.head = 0;
        queue.resync_workspace = null;
        queue.resync_previous_workspace = null;
    }
};

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
