const PaneMouseHandler = @This();
const Plans = @import("Plans.zig");
const Effects = @import("PaneMouseEffects.zig");
const source_namespace = @import("pane_mouse.zig");
plans: Plans,
effects: Effects,

/// Resolves one pane snapshot, then selects one mouse-selection,
/// viewport, alternate-scroll or child mouse-report effect.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(self: *PaneMouseHandler, command: source_namespace.Command) !source_namespace.Outcome {
    const resolved = self.plans.resolve(self.plans.context, command) orelse return .ignored;
    const plan = resolved.plan;
    const pointer = resolved.pointer;

    const forced_selection = pointer.event.button & 4 != 0;
    if (pointer.event.kind == .press and pointer.event.button & 0b11 == 0 and
        (plan.protocol.tracking == .none or forced_selection))
    {
        try self.effects.apply(self.effects.context, .{ .selection = .{
            .plan = plan,
            .command = pointer,
        } });
        return .selection_started;
    }

    const wheel_delta: ?i32 = switch (pointer.event.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => null,
    };

    const tracked = plan.protocol.sgr and source_namespace.mouse_protocol.tracked(plan.protocol.tracking, pointer.event.kind);

    if (wheel_delta) |delta| {
        if (!tracked) {
            if (plan.alternate_scroll and plan.at_bottom) {
                try self.effects.apply(self.effects.context, .{ .alternate_scroll = .{
                    .pane_id = plan.pane_id,
                    .delta = delta,
                } });
                return .alternate_scroll_selected;
            }

            try self.effects.apply(self.effects.context, .{ .viewport = .{
                .pane_id = plan.pane_id,
                .delta = delta,
            } });
            return .viewport_selected;
        }
    }

    if (!tracked) {
        return .ignored;
    }

    try self.effects.apply(self.effects.context, .{ .report = .{
        .plan = plan,
        .command = pointer,
    } });
    return .report_selected;
}
