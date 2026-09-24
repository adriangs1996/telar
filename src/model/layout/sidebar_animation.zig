//! The sidebar's activity animation: whether it runs and each step.

const model_data = @import("../model.zig");
const sidebar = @import("sidebar.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Reports whether the latest runtime state requires sidebar animation.
///
/// ```zig
/// if (sidebar_animation.isActive(model)) scheduleTick();
/// ```
pub fn isActive(model: *const ClientModel) bool {
    if (model.agent_snapshot.hasWorkingAgent()) {
        return true;
    }

    var panes = model.panes.iterateConst(null);
    while (panes.next()) |pane| {
        if (pane.progress_state == .set or pane.progress_state == .indeterminate) {
            return true;
        }
    }

    return false;
}

/// Advances the visible sidebar animation only while a working agent
/// exists and publishes one dedicated presenter revision.
///
/// ```zig
/// const change = sidebar_animation.advance(model) orelse return;
/// ```
pub fn advance(model: *ClientModel) ?model_data.SidebarAnimationChange {
    if (!isActive(model)) {
        return null;
    }

    model.sidebar_animation_frame +%= 1;
    model.sidebar_animation_revision +%= 1;

    return .{
        .frame = model.sidebar_animation_frame,
        .sidebar_animation_revision = model.sidebar_animation_revision,
    };
}
