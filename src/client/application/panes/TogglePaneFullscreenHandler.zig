const TogglePaneFullscreenHandler = @This();
const client_model = @import("../../root.zig").model;
const FullscreenEffects = @import("FullscreenEffects.zig");
const source_namespace = @import("toggle_pane_fullscreen.zig");
model: *client_model.Model,
effects: FullscreenEffects,

/// Commits fullscreen state before delivering graphics and runtime
/// geometry. Absent or empty layouts have no effects.
///
/// ```zig
/// const change = try handler.execute(.{ .area = area });
/// ```
pub fn execute(handler: *TogglePaneFullscreenHandler, command: source_namespace.TogglePaneFullscreen) !?client_model.PaneGeometryChange {
    const change = handler.model.togglePaneFullscreen(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, change);
    return change;
}
