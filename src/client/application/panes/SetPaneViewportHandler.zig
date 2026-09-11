const SetPaneViewportHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneViewportEffects = @import("PaneViewportEffects.zig");
const source_namespace = @import("set_pane_viewport.zig");
model: *client_model.Model,
effects: PaneViewportEffects,

/// Commits a bounded client viewport before synchronizing graphics and
/// the runtime. Invalid targets and repeated offsets have no effects.
///
/// ```zig
/// const change = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *SetPaneViewportHandler, command: source_namespace.SetPaneViewport) !?client_model.PaneViewportChange {
    const change = handler.model.setPaneViewport(command) orelse return null;

    try handler.effects.sync(handler.effects.context, change);
    return change;
}
