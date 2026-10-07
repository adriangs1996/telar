//! Pure repeat policy for configured actions.
const keyinput = @import("keyinput");
const core = @import("telar-core");
const model_data = @import("model");
const std = @import("std");

/// Only native wheel-step actions with an eligible pane may repeat, at most ten steps per second.
/// For example: `const policy = repeatPolicy(.{ .scroll_pane = .up }, pane_id);`.
pub fn repeatPolicy(value: model_data.Action, eligible_pane: ?core.PaneId) ?keyinput.RepeatPolicy {
    const pane_id = eligible_pane orelse return null;

    return switch (value) {
        .scroll_pane => .{ .interval_ns = 100 * std.time.ns_per_ms, .context = @intFromEnum(pane_id) },
        else => null,
    };
}
