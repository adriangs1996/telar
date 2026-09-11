const ViewInteractionEffects = @import("ViewInteractionEffects.zig");
const ViewInteractionCommand = @import("ViewInteractionCommand.zig");
const ViewInteractionOutcome = @import("ViewInteractionOutcome.zig");
const view_interaction = @import("view_interaction.zig");
const DispatchViewInteractionHandler = @This();

effects: ViewInteractionEffects,

/// Applies the single semantic intent before ordered layout delivery, then
/// returns only the routing decision needed by host input.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *DispatchViewInteractionHandler, command: ViewInteractionCommand) !ViewInteractionOutcome {
    var layout_changed = command.layout_changed;
    switch (command.intent) {
        .none => {},
        else => {
            const applied = try handler.effects.apply_intent(handler.effects.context, command.intent);
            layout_changed = layout_changed or applied.layout_changed;
        },
    }

    if (layout_changed) {
        handler.effects.invalidate_graphics_placements(handler.effects.context);
        try handler.effects.offer_pane_geometry(handler.effects.context);
    }

    return .{
        .consume_pane_input = command.consumed or view_interaction.capturesPaneInput(command.intent),
    };
}
