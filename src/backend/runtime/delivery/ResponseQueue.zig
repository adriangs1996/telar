const ResponseQueue = @This();
const source_namespace = @import("response_queue.zig");
const PendingNotification = @import("PendingNotification.zig");
const std = @import("std");
items: [source_namespace.capacity]source_namespace.PendingResponse = undefined,
head: u8 = 0,
len: u8 = 0,
high_water: u8 = 0,
dropped: u64 = 0,
resync_workspace: ?source_namespace.schema.WorkspaceLocation = null,
resync_previous_workspace: ?source_namespace.schema.WorkspaceId = null,

pub const Entry = struct {
    offset: u8,
    response: *source_namespace.PendingResponse,
};

pub fn push(queue: *ResponseQueue, response: source_namespace.PendingResponse) !void {
    if (queue.len == queue.items.len) {
        return error.ResponseQueueFull;
    }

    const index = (@as(usize, queue.head) + queue.len) % queue.items.len;
    queue.items[index] = response;
    queue.len += 1;
    queue.high_water = @max(queue.high_water, queue.len);
}

/// Observation notifications may be dropped under backpressure. State
/// notifications record the workspace that must be resynchronized.
///
/// ```zig
/// queue.pushOrDrop(response);
/// ```
pub fn pushOrDrop(queue: *ResponseQueue, response: source_namespace.PendingResponse) void {
    queue.push(response) catch {
        switch (response) {
            .history_result => |result| result.deinit(),
            .history_output => |result| result.deinit(),
            .history_stats => |result| result.deinit(),
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

pub fn pushAgentSound(queue: *ResponseQueue, sound: source_namespace.schema.AgentSoundNotification) bool {
    queue.push(.{ .agent_sound = sound }) catch {
        queue.dropped += 1;
        return false;
    };
    return true;
}

/// Reserves the exact confirmation slot before a notification is
/// published. The returned pointer remains stable while synchronous
/// publication appends other fixed-capacity queue entries.
///
/// ```zig
/// const shown = try queue.reserveNotificationShown(request_id);
/// shown.delivered_clients = delivered;
/// ```
pub fn reserveNotificationShown(queue: *ResponseQueue, request_id: source_namespace.schema.RequestId) !*source_namespace.schema.NotificationShown {
    try queue.push(.{ .notification_shown = .{
        .request_id = request_id,
        .delivered_clients = 0,
    } });

    const index = (@as(usize, queue.head) + queue.len - 1) % queue.items.len;
    return &queue.items[index].notification_shown;
}

pub fn peek(queue: *ResponseQueue) ?*source_namespace.PendingResponse {
    if (queue.len == 0) {
        return null;
    }

    return &queue.items[queue.head];
}

pub fn peekManagement(queue: *ResponseQueue) ?Entry {
    for (0..queue.len) |offset| {
        const index = (@as(usize, queue.head) + offset) % queue.items.len;

        if (queue.items[index] == .history_result) {
            continue;
        }

        return .{ .offset = @intCast(offset), .response = &queue.items[index] };
    }
    return null;
}

pub fn peekObservation(queue: *ResponseQueue) ?Entry {
    for (0..queue.len) |offset| {
        const index = (@as(usize, queue.head) + offset) % queue.items.len;

        if (queue.items[index] != .history_result) {
            continue;
        }

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
            .history_output => |result| result.deinit(),
            .history_stats => |result| result.deinit(),
            else => {},
        }
        queue.pop();
    }
    queue.head = 0;
    queue.resync_workspace = null;
    queue.resync_previous_workspace = null;
}
