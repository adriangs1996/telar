const ToggleSidebarHandler = @This();
const client_model = @import("../../root.zig").model;
const SidebarEffects = @import("SidebarEffects.zig");
model: *client_model.Model,
effects: SidebarEffects,

/// Commits the sidebar preference before synchronizing its disposable
/// projection and pane geometry.
///
/// ```zig
/// const change = try handler.execute();
/// ```
pub fn execute(handler: *ToggleSidebarHandler) !client_model.SidebarLayout {
    const change = handler.model.toggleSidebar();

    try handler.effects.apply(handler.effects.context, change);
    return change;
}
