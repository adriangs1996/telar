const DispatchViewInteractionHandler = @This();
const Effects = @import("ViewInteractionEffects.zig");
const Command = @import("ViewInteractionCommand.zig");
const Outcome = @import("ViewInteractionOutcome.zig");
const source_namespace = @import("view_interaction.zig");
effects: Effects,

/// Applies the single semantic intent before ordered layout delivery, then
/// returns only the routing decision needed by host input.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *DispatchViewInteractionHandler, command: Command) !Outcome {
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
        .consume_pane_input = command.consumed or source_namespace.capturesPaneInput(command.intent),
    };
}
