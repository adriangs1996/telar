const ModelType = @import("../../model/Model.zig");
const SidebarAnimationEffects = @import("SidebarAnimationEffects.zig");
const sidebar_animation = @import("sidebar_animation.zig");
const SidebarAnimationChangeType = @import("../../model/SidebarAnimationChange.zig");
const SidebarAnimationHandler = @This();

model: *ModelType,
effects: SidebarAnimationEffects,

/// Ensures an active animation has one future tick without changing its
/// visible frame.
///
/// ```zig
/// _ = try handler.synchronize();
/// ```
pub fn synchronize(handler: *SidebarAnimationHandler) !sidebar_animation.Activity {
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
pub fn tick(handler: *SidebarAnimationHandler) !?SidebarAnimationChangeType {
    const change = handler.model.advanceSidebarAnimation() orelse return null;

    try handler.effects.schedule(handler.effects.context);
    return change;
}
