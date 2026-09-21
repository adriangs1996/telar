//! Pure repeat policy for configured actions.
const action_module = @import("../../input/action.zig");
const PaneIdType = @import("telar-core").PaneId;
const RepeatPolicyType = @import("../../input/RepeatPolicy.zig");
const std = @import("std");

/// Only native wheel-step actions with an eligible pane may repeat, at most ten steps per second.
/// For example: `const policy = repeatPolicy(.{ .scroll_pane = .up }, pane_id);`.
pub fn repeatPolicy(value: action_module.Action, eligible_pane: ?PaneIdType) ?RepeatPolicyType {
    const pane_id = eligible_pane orelse return null;

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

test "repeat policy rejects unavailable targets and changes context with pane identity" {
    const value: action_module.Action = .{
        .scroll_pane = .up,
    };
    try std.testing.expect(repeatPolicy(value, null) == null);
    const first = repeatPolicy(value, @enumFromInt(7)).?;
    const second = repeatPolicy(value, @enumFromInt(8)).?;
    try std.testing.expect(first.context != second.context);
    try std.testing.expectEqual(first.interval_ns, second.interval_ns);
}
