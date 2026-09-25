const core = @import("telar-core");
const response_queue = @import("response_queue.zig");
const PendingNotification = @import("PendingNotification.zig");
const std = @import("std");
const ResponseQueue = @This();

items: [response_queue.capacity]response_queue.PendingResponse = undefined,
head: u8 = 0,
len: u8 = 0,
high_water: u8 = 0,
dropped: u64 = 0,
resync_workspace: ?core.WorkspaceLocation = null,
resync_previous_workspace: ?core.WorkspaceId = null,

pub const Entry = @import("Entry.zig");

pub fn push(self: *ResponseQueue, response: response_queue.PendingResponse) !void {
    if (self.len == self.items.len) {
        return error.ResponseQueueFull;
    }

    const index = (@as(usize, self.head) + self.len) % self.items.len;
    self.items[index] = response;
    self.len += 1;
    self.high_water = @max(self.high_water, self.len);
}

/// Observation notifications may be dropped under backpressure. State
/// notifications record the workspace that must be resynchronized.
///
/// ```zig
/// queue.pushOrDrop(response);
/// ```
pub fn pushOrDrop(self: *ResponseQueue, response: response_queue.PendingResponse) void {
    self.push(response) catch {
        switch (response) {
            .history_result => |result| result.deinit(),
            .change_review => |result| result.deinit(),
            .history_output => |result| result.deinit(),
            .history_stats => |result| result.deinit(),
            .tab_closed => |closed| {
                self.resync_workspace = closed.location.workspace;
                self.resync_previous_workspace = closed.previous_workspace;
            },
            .tab_moved => |moved| {
                self.resync_workspace = moved.location.workspace;
                self.resync_previous_workspace = null;
            },
            else => {},
        }
        self.dropped += 1;
    };
}

pub fn pushNotification(self: *ResponseQueue, notification: PendingNotification) bool {
    self.push(.{ .notification = notification }) catch {
        self.dropped += 1;
        return false;
    };
    return true;
}

pub fn pushAgentSound(self: *ResponseQueue, sound: core.AgentSoundNotification) bool {
    self.push(.{ .agent_sound = sound }) catch {
        self.dropped += 1;
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
pub fn reserveNotificationShown(self: *ResponseQueue, request_id: core.RequestId) !*core.NotificationShown {
    try self.push(.{ .notification_shown = .{
        .request_id = request_id,
        .delivered_clients = 0,
    } });

    const index = (@as(usize, self.head) + self.len - 1) % self.items.len;
    return &self.items[index].notification_shown;
}

/// Keeps one owned review result reserved through socket send admission.
/// Example: `if (queue.hasChangeReview()) return error.ReviewBusy;`.
pub fn hasChangeReview(self: *const ResponseQueue) bool {
    return self.contains(.change_review);
}

fn contains(self: *const ResponseQueue, tag: std.meta.Tag(response_queue.PendingResponse)) bool {
    for (0..self.len) |offset| {
        const index = (@as(usize, self.head) + offset) % self.items.len;
        if (std.meta.activeTag(self.items[index]) == tag) {
            return true;
        }
    }

    return false;
}

pub fn peek(self: *ResponseQueue) ?*response_queue.PendingResponse {
    if (self.len == 0) {
        return null;
    }

    return &self.items[self.head];
}

pub fn peekManagement(self: *ResponseQueue) ?Entry {
    for (0..self.len) |offset| {
        const index = (@as(usize, self.head) + offset) % self.items.len;

        if (self.items[index] == .history_result) {
            continue;
        }

        return .{ .offset = @intCast(offset), .response = &self.items[index] };
    }
    return null;
}

pub fn peekObservation(self: *ResponseQueue) ?Entry {
    for (0..self.len) |offset| {
        const index = (@as(usize, self.head) + offset) % self.items.len;

        if (self.items[index] != .history_result) {
            continue;
        }

        return .{ .offset = @intCast(offset), .response = &self.items[index] };
    }
    return null;
}

pub fn pop(self: *ResponseQueue) void {
    std.debug.assert(self.len != 0);
    self.head = @intCast((@as(usize, self.head) + 1) % self.items.len);
    self.len -= 1;
}

pub fn removeAt(self: *ResponseQueue, offset: u8) void {
    std.debug.assert(offset < self.len);
    var cursor: usize = offset;
    while (cursor + 1 < self.len) : (cursor += 1) {
        const destination = (@as(usize, self.head) + cursor) % self.items.len;
        const source = (@as(usize, self.head) + cursor + 1) % self.items.len;
        self.items[destination] = self.items[source];
    }
    self.len -= 1;
}

pub fn clear(self: *ResponseQueue) void {
    while (self.peek()) |response| {
        switch (response.*) {
            .history_result => |result| result.deinit(),
            .change_review => |result| result.deinit(),
            .history_output => |result| result.deinit(),
            .history_stats => |result| result.deinit(),
            else => {},
        }
        self.pop();
    }
    self.head = 0;
    self.resync_workspace = null;
    self.resync_previous_workspace = null;
}
