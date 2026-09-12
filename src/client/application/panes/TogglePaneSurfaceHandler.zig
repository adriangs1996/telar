const ModelType = @import("../../model/Model.zig");
const PaneSurfaceType = @import("telar-core").PaneSurface;
const TogglePaneSurfaceHandler = @This();

model: *ModelType,

/// Commits the focused pane's next surface; presentation observes the pane
/// version. Absent layouts commit nothing.
///
/// ```zig
/// const surface = handler.execute() orelse return;
/// ```
pub fn execute(handler: *TogglePaneSurfaceHandler) ?PaneSurfaceType {
    return handler.model.togglePaneSurface();
}
