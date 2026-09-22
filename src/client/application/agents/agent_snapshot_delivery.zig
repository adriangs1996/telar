//! Application policy for delivering dependent client state after one agent
//! snapshot commit.
const core = @import("telar-core");
const model_data = @import("model");

const std = @import("std");

pub fn alertInput(change: model_data.AgentStatusChange, label: []const u8, message_buffer: *[96]u8) ?model_data.NotificationInput {
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
            7 * std.time.ns_per_s
        else
            model_data.notifications.default_duration_ns,
    };
}

fn statusName(status: core.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .done => "done",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}
