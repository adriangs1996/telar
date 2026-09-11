const ResizeSidebarHandler = @This();
const client_model = @import("../../root.zig").model;
const SidebarEffects = @import("SidebarEffects.zig");
const source_namespace = @import("toggle_sidebar.zig");
model: *client_model.Model,
effects: SidebarEffects,

/// Commits one exact or stepped width before synchronizing geometry.
///
/// ```zig
/// _ = try handler.execute(.{ .exact = 73 });
/// ```
pub fn execute(handler: *ResizeSidebarHandler, resize: source_namespace.Resize) !?client_model.SidebarLayout {
    const change = switch (resize) {
        .exact => |width| handler.model.setSidebarWidth(width),
        .direction => |direction| handler.model.stepSidebarWidth(direction),
    } orelse return null;

    try handler.effects.apply(handler.effects.context, change);
    return change;
}
