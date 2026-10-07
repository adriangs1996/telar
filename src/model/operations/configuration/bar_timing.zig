const std = @import("std");
const model = @import("../../bars/model.zig");
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
