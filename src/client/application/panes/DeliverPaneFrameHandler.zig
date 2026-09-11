const DeliverPaneFrameHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneFrameDeliveryEffects.zig");
const std = @import("std");
model: *const client_model.Model,
effects: Effects,

/// Validates one exact frame commit before reconciling graphics visibility
/// and the resources derived from the currently active pane.
///
/// ```zig
/// try handler.execute(commit);
/// ```
pub fn execute(handler: *DeliverPaneFrameHandler, commit: client_model.PaneFrameCommit) !void {
    try handler.validate(commit);

    const visible = handler.effects.pane_graphics_visible(handler.effects.context, commit.pane_id);
    if (visible != commit.graphics_visible) {
        try handler.effects.set_pane_graphics_visible(
            handler.effects.context,
            commit.pane_id,
            commit.graphics_visible,
        );
    }

    if (handler.model.workspace.activeConst() != null) {
        try handler.effects.synchronize_active_resources(handler.effects.context);
    }
}

fn validate(handler: *const DeliverPaneFrameHandler, commit: client_model.PaneFrameCommit) !void {
    const tab = handler.model.workspace.tabForPaneConst(commit.pane_id) orelse return error.StalePaneFrame;
    if (!std.meta.eql(tab.location, commit.location)) {
        return error.StalePaneFrame;
    }

    const pane = tab.model.findConst(commit.pane_id) orelse return error.StalePaneFrame;
    const active = handler.model.workspace.activeConst();
    const graphics_visible = pane.scroll.atBottom(pane.buffer.h) and
        active != null and std.meta.eql(active.?.location, tab.location);
    const version = handler.model.version();
    if (!pane.attached or
        pane.applied_frame_id != commit.frame_id or
        graphics_visible != commit.graphics_visible or
        version.workspace != commit.workspace_revision or
        version.tabs != commit.tabs_revision or
        version.active_tab != commit.active_tab_revision or
        version.panes != commit.panes_revision or
        version.frame != commit.frame_revision)
    {
        return error.StalePaneFrame;
    }
}
