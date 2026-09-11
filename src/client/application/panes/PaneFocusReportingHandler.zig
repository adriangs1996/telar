const PaneFocusReportingHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneFocusReportingEffects.zig");
const source_namespace = @import("pane_focus_reporting.zig");
model: *client_model.Model,
effects: Effects,

/// Commits one reporting transition before emitting focus-out and
/// focus-in in protocol order.
///
/// ```zig
/// _ = try handler.execute(.sync);
/// ```
pub fn execute(handler: *PaneFocusReportingHandler, command: source_namespace.Command) !source_namespace.Outcome {
    const transition = switch (command) {
        .sync => handler.model.syncReportedPaneFocus(),
        .clear => handler.model.clearReportedPaneFocus(),
    } orelse return .unchanged;

    if (transition.focus_out) |pane_id| {
        try handler.effects.deliver(handler.effects.context, .{
            .pane_id = pane_id,
            .direction = .focus_out,
        });
    }

    if (transition.focus_in) |pane_id| {
        try handler.effects.deliver(handler.effects.context, .{
            .pane_id = pane_id,
            .direction = .focus_in,
        });
    }

    return .applied;
}
