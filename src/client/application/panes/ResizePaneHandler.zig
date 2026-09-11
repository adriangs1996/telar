const ResizePaneHandler = @This();
const client_model = @import("../../root.zig").model;
const ResizeEffects = @import("ResizeEffects.zig");
const source_namespace = @import("resize_pane.zig");
model: *client_model.Model,
effects: ResizeEffects,

/// Commits one split-edge change before delivering runtime geometry.
/// Directions without a matching movable edge have no effects.
///
/// ```zig
/// const resize = try handler.execute(.{ .direction = .right, .area = area });
/// ```
pub fn execute(handler: *ResizePaneHandler, command: source_namespace.ResizePane) !?client_model.PaneGeometryChange {
    const resize = handler.model.resizePane(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, resize);
    return resize;
}
