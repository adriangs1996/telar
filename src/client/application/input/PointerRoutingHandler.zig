const PointerRoutingEffects = @import("PointerRoutingEffects.zig");
const pointer_routing = @import("pointer_routing.zig");
const PointerRoutingHandler = @This();

effects: PointerRoutingEffects,

/// Gives each pointer event to the first owner that accepts it.
///
/// ```zig
/// const outcome = try handler.execute(authority);
/// ```
pub fn execute(handler: *PointerRoutingHandler, authority: pointer_routing.Authority) !pointer_routing.Outcome {
    const command = switch (authority) {
        .unavailable => return .unavailable,
        .available => |available| available,
    };

    if (try handler.effects.copy_mode(handler.effects.context, command)) {
        return .copy_mode;
    }

    const view = try handler.effects.view(handler.effects.context, command);
    if (view.consume_pane_input or !view.pointer_inside) {
        return .view;
    }

    if (try handler.effects.link(handler.effects.context, command)) {
        return .link;
    }

    try handler.effects.pane(handler.effects.context, command);
    return .pane;
}
