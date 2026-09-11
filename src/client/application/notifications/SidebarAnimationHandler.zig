const SidebarAnimationHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("SidebarAnimationEffects.zig");
const source_namespace = @import("sidebar_animation.zig");
model: *client_model.Model,
effects: Effects,

/// Ensures an active animation has one future tick without changing its
/// visible frame.
///
/// ```zig
/// _ = try handler.synchronize();
/// ```
pub fn synchronize(handler: *SidebarAnimationHandler) !source_namespace.Activity {
    if (!handler.model.sidebarAnimationActive()) {
        return .inactive;
    }

    try handler.effects.schedule(handler.effects.context);
    return .active;
}

/// Commits one visible frame before rearming the animation scheduler.
///
/// ```zig
/// _ = try handler.tick();
/// ```
pub fn tick(handler: *SidebarAnimationHandler) !?client_model.SidebarAnimationChange {
    const change = handler.model.advanceSidebarAnimation() orelse return null;

    try handler.effects.schedule(handler.effects.context);
    return change;
}
