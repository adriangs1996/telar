const ModelType = @import("../../model/Model.zig");
const PaneFocusReportingEffects = @import("PaneFocusReportingEffects.zig");
const pane_focus_reporting = @import("pane_focus_reporting.zig");
const PaneFocusReportingHandler = @This();

model: *ModelType,
effects: PaneFocusReportingEffects,

/// Commits one reporting transition before emitting focus-out and
/// focus-in in protocol order.
///
/// ```zig
/// _ = try handler.execute(.sync);
/// ```
pub fn execute(handler: *PaneFocusReportingHandler, command: pane_focus_reporting.Command) !pane_focus_reporting.Outcome {
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
