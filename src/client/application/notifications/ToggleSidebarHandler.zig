const ModelType = @import("../../model/Model.zig");
const SidebarEffects = @import("SidebarEffects.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const ToggleSidebarHandler = @This();

model: *ModelType,
effects: SidebarEffects,

/// Commits the sidebar preference before synchronizing its disposable
/// projection and pane geometry.
///
/// ```zig
/// const change = try handler.execute();
/// ```
pub fn execute(handler: *ToggleSidebarHandler) !SidebarLayoutType {
    const change = handler.model.toggleSidebar();

    try handler.effects.apply(handler.effects.context, change);
    return change;
}
