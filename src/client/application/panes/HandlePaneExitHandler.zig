const HandlePaneExitHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneExitEffects = @import("PaneExitEffects.zig");
const source_namespace = @import("close_pane.zig");
model: *client_model.Model,
effects: PaneExitEffects,

/// Commits pane retirement before releasing client resources. Stale exit
/// traffic still runs idempotent cleanup so pending requests can settle.
///
/// ```zig
/// const transition = try handler.execute(pane_id);
/// ```
pub fn execute(handler: *HandlePaneExitHandler, pane_id: source_namespace.schema.PaneId) !source_namespace.PaneExit {
    const transition = handler.model.retirePane(pane_id);
    try handler.effects.deliver(handler.effects.context, transition);

    return transition;
}
