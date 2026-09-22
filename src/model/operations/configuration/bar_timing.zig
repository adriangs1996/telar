const std = @import("std");
const model = @import("../../bars/model.zig");
const ConfigurationType = @import("../../bars/BarConfiguration.zig");
const State = @import("../../bars/BarUpdatesState.zig");
const command_execution = @import("../../bars/command_execution.zig");

pub const no_deadline: u64 = std.math.maxInt(u64);
pub const position_count = @typeInfo(model.Position).@"enum".fields.len;
pub const CommandExecutionId = command_execution.Id;

/// Advances past elapsed ticks without enqueueing missed updates.
/// Example: `const next = followingDeadline(1000, 100, 1750); // 1800`
pub fn followingDeadline(deadline_ns: u64, interval_ns: u64, now_ns: u64) u64 {
    std.debug.assert(interval_ns != 0);
    const elapsed = now_ns - deadline_ns;
    const skipped = elapsed / interval_ns;
    const increment = std.math.mul(u64, skipped + 1, interval_ns) catch return no_deadline;

    return deadline_ns +| increment;
}

test "bar deadlines start immediately and coalesce elapsed intervals" {
    const configuration: ConfigurationType = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 4, .id = 0 }, .interval_ns = 100 } },
            .{ .command = .{ .generation = 4, .interval_ns = 250, .timeout_ms = 100 } },
            .tabs,
        },
    };
    var state: State = .{};
    state.synchronize(.{ .generation = 4, .configuration = &configuration, .now_ns = 1_000 });

    try std.testing.expectEqual(@as(?u64, 1_000), state.nextDeadline());
    const due = state.takeDue(.{
        .generation = 4,
        .configuration = &configuration,
        .now_ns = 1_750,
    });

    try std.testing.expectEqual(model.Position.bottom_left.bit(), due.dynamic_mask);
    try std.testing.expectEqual(model.Position.bottom_center.bit(), due.command_mask);
    try std.testing.expectEqual(@as(u64, 1_800), state.deadlines[@intFromEnum(model.Position.bottom_left)]);
    try std.testing.expectEqual(@as(u64, 2_000), state.deadlines[@intFromEnum(model.Position.bottom_center)]);
}

test "bar synchronization clears queued work but preserves one in-flight command identity" {
    var state: State = .{};
    state.pending_callbacks = model.Position.top_right.bit();
    state.pending_commands = model.Position.bottom_left.bit();
    const execution = try state.reserveCommand(3, .bottom_left);

    state.synchronize(.{ .generation = 4, .configuration = null, .now_ns = 2_000 });

    try std.testing.expectEqual(@as(u8, 0), state.pending_callbacks);
    try std.testing.expectEqual(@as(u8, 0), state.pending_commands);
    try std.testing.expectEqual(execution, state.command_execution.?);
    try std.testing.expectEqual(execution, state.finishCommand(execution.id).?);
    try std.testing.expect(state.command_execution == null);
}
