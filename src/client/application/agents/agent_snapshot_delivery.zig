//! Application policy for delivering dependent client state after one agent
//! snapshot commit.

const AgentStatusChangeType = @import("../../model/AgentStatusChange.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const notification_capability = @import("../../notifications/notifications.zig");
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;

pub fn alertInput(change: AgentStatusChangeType, label: []const u8, message_buffer: *[96]u8) ?InputType {
    const level: notification_capability.Level = switch (change.current) {
        .blocked => .warning,
        .done => .success,
        .failed => .failure,
        .unknown, .working, .ready => return null,
    };
    const message = std.fmt.bufPrint(
        message_buffer,
        "{s} in pane {d} is {s}",
        .{ label, change.pane_index, statusName(change.current) },
    ) catch "Agent status changed";

    return .{
        .level = level,
        .title = switch (change.current) {
            .blocked => "Agent needs input",
            .done => "Agent done",
            .failed => "Agent failed",
            .unknown, .working, .ready => unreachable,
        },
        .message = message,
        .target = .{ .focus_pane = change.key.pane_id },
        .duration_ns = if (change.current == .failed)
            7 * std.time.ns_per_s
        else
            notification_capability.default_duration_ns,
    };
}

fn statusName(status: AgentStatusType) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .done => "done",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}
