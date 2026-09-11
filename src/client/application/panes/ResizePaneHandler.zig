const ModelType = @import("../../model/Model.zig");
const ResizeEffects = @import("ResizeEffects.zig");
const ResizePaneRequest = @import("../../model/ResizePaneRequest.zig");
const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const ResizePaneHandler = @This();

model: *ModelType,
effects: ResizeEffects,

/// Commits one split-edge change before delivering runtime geometry.
/// Directions without a matching movable edge have no effects.
///
/// ```zig
/// const resize = try handler.execute(.{ .direction = .right, .area = area });
/// ```
pub fn execute(handler: *ResizePaneHandler, command: ResizePaneRequest) !?PaneGeometryChangeType {
    const resize = handler.model.resizePane(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, resize);
    return resize;
}
