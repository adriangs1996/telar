const ModelType = @import("../../model/Model.zig");
const FullscreenEffects = @import("FullscreenEffects.zig");
const TogglePaneFullscreenRequest = @import("../../model/TogglePaneFullscreenRequest.zig");
const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const TogglePaneFullscreenHandler = @This();

model: *ModelType,
effects: FullscreenEffects,

/// Commits fullscreen state before delivering graphics and runtime
/// geometry. Absent or empty layouts have no effects.
///
/// ```zig
/// const change = try handler.execute(.{ .area = area });
/// ```
pub fn execute(handler: *TogglePaneFullscreenHandler, command: TogglePaneFullscreenRequest) !?PaneGeometryChangeType {
    const change = handler.model.togglePaneFullscreen(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, change);
    return change;
}
