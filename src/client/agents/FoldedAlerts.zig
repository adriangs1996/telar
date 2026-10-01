//! The alerts one agent snapshot raised past what the notification center
//! shows one by one, counted by status for one summary alert.
const std = @import("std");
const model_data = @import("model");
const agent_snapshot_delivery = @import("agent_snapshot_delivery.zig");
const FoldedAlerts = @This();

blocked: usize = 0,
done: usize = 0,
failed: usize = 0,

/// Counts one alert that did not get its own notification.
///
/// ```zig
/// folded.add(change);
/// ```
pub fn add(self: *FoldedAlerts, change: model_data.AgentStatusChange) void {
    switch (change.current) {
        .blocked => self.blocked += 1,
        .done => self.done += 1,
        .failed => self.failed += 1,
        .unknown, .working, .ready => {},
    }
}

/// One alert for every folded agent, at the level of the most severe
/// one; null when nothing was folded.
///
/// ```zig
/// const summary = folded.summaryInput(&buffer) orelse return;
/// ```
pub fn summaryInput(self: FoldedAlerts, message_buffer: *agent_snapshot_delivery.MessageBuffer) ?model_data.NotificationInput {
    const total = self.blocked + self.done + self.failed;
    if (total == 0) {
        return null;
    }

    var writer: std.Io.Writer = .fixed(message_buffer);
    writer.print("{d} more agents:", .{total}) catch {};
    writeCount(&writer, self.blocked, agent_snapshot_delivery.statusName(.blocked), false);
    writeCount(&writer, self.done, agent_snapshot_delivery.statusName(.done), self.blocked != 0);
    writeCount(&writer, self.failed, agent_snapshot_delivery.statusName(.failed), self.blocked + self.done != 0);

    const level: model_data.NotificationLevel = if (self.failed != 0) .failure else if (self.blocked != 0) .warning else .success;
    return .{
        .level = level,
        .title = "More agents changed",
        .message = writer.buffered(),
        .duration_ns = if (self.failed != 0) agent_snapshot_delivery.failed_duration_ns else model_data.notifications.default_duration_ns,
    };
}

fn writeCount(writer: *std.Io.Writer, count: usize, status: []const u8, separated: bool) void {
    if (count == 0) {
        return;
    }

    const separator = if (separated) "," else "";
    writer.print("{s} {d} {s}", .{ separator, count, status }) catch {};
}
