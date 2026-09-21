//! Pure repeat policy for configured actions.
const action_module = @import("../../input/action.zig");
const PaneIdType = @import("telar-core").PaneId;
const RepeatPolicyType = @import("../../input/RepeatPolicy.zig");
const std = @import("std");

/// Only native wheel-step actions may repeat, at most ten steps per second.
/// For example: `const policy = repeatPolicy(.{ .scroll_pane = .up }, pane_id);`.
pub fn repeatPolicy(value: action_module.Action, pane_id: PaneIdType) ?RepeatPolicyType {
    return switch (value) {
        .scroll_pane => .{ .interval_ns = 100 * std.time.ns_per_ms, .context = @intFromEnum(pane_id) },
        else => null,
    };
}

test "repeat policy enables only native scroll with exact pane ownership" {
    const pane_id: PaneIdType = @enumFromInt(7);
    for ([_]action_module.ScrollDirection{ .up, .down }) |direction| {
        const policy = repeatPolicy(.{ .scroll_pane = direction }, pane_id).?;
        try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), policy.interval_ns);
        try std.testing.expectEqual(@as(u64, 7), policy.context);
    }

    const non_repeating = [_]action_module.Action{
        .close_pane,
        .close_tab,
        .detach,
        .toggle_sidebar,
        .enter_copy_mode,
        .{ .focus_pane = .left },
        .{ .lua_callback = .{ .generation = 1, .id = 1 } },
        .{ .lua_expr = .{ .generation = 1, .id = 1 } },
        .{ .plugin = .{ .plugin = 1, .action = 1 } },
    };

    for (non_repeating) |value| {
        try std.testing.expect(repeatPolicy(value, pane_id) == null);
    }
}
