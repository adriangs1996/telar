const ModelType = @import("../../model/Model.zig");
const SidebarEffects = @import("SidebarEffects.zig");
const toggle_sidebar = @import("toggle_sidebar.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const ResizeSidebarHandler = @This();

model: *ModelType,
effects: SidebarEffects,

/// Commits one exact or stepped width before synchronizing geometry.
///
/// ```zig
/// _ = try handler.execute(.{ .exact = 73 });
/// ```
pub fn execute(handler: *ResizeSidebarHandler, resize: toggle_sidebar.Resize) !?SidebarLayoutType {
    const change = switch (resize) {
        .exact => |width| handler.model.setSidebarWidth(width),
        .direction => |direction| handler.model.stepSidebarWidth(direction),
    } orelse return null;

    try handler.effects.apply(handler.effects.context, change);
    return change;
}
