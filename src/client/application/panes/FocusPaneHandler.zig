const FocusPaneHandler = @This();
const client_model = @import("../../root.zig").model;
const FocusEffects = @import("FocusEffects.zig");
const source_namespace = @import("focus_pane.zig");
model: *client_model.Model,
effects: FocusEffects,

/// Commits one focus change before delivering it to active-pane resources.
/// A rejected or repeated target has no effects.
///
/// ```zig
/// const focus = try handler.execute(.{ .target = .{ .pane_id = pane_id }, .area = area });
/// ```
pub fn execute(handler: *FocusPaneHandler, command: source_namespace.FocusPane) !?client_model.PaneFocus {
    const focus = handler.model.focusPane(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, focus, command.area);
    return focus;
}
