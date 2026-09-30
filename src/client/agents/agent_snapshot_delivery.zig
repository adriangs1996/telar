//! Application policy for delivering dependent client state after one agent
//! snapshot commit.
const core = @import("telar-core");
const model_data = @import("model");

const std = @import("std");

/// Text of one agent alert: a display name, a pane number and a status fit
/// with room to spare.
pub const MessageBuffer = [96]u8;

/// Whether a status change raises an alert: only an agent that became
/// blocked, done or failed does.
///
/// ```zig
/// if (agent_snapshot_delivery.alerts(change)) count += 1;
/// ```
pub fn alerts(change: model_data.AgentStatusChange) bool {
    return switch (change.current) {
        .blocked, .done, .failed => true,
        .unknown, .working, .ready => false,
    };
}

/// How long an alert about a failed agent stays on screen.
pub const failed_duration_ns = 7 * std.time.ns_per_s;

pub fn alertInput(change: model_data.AgentStatusChange, label: []const u8, message_buffer: *MessageBuffer) ?model_data.NotificationInput {
    const level: model_data.NotificationLevel = switch (change.current) {
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
            failed_duration_ns
        else
            model_data.notifications.default_duration_ns,
    };
}

/// How an alert names an agent's status.
pub fn statusName(status: core.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .done => "done",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}
