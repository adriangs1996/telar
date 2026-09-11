const ActivateWorkspaceHandler = @This();
const client_model = @import("../../root.zig").model;
const ActivationEffects = @import("ActivationEffects.zig");
const std = @import("std");
model: *client_model.Model,
effects: ActivationEffects,

/// Validates one exact activation before synchronizing active resources,
/// host input and canonical snapshot requests in order.
///
/// ```zig
/// try handler.execute(activation);
/// ```
pub fn execute(handler: *ActivateWorkspaceHandler, activation: client_model.WorkspaceActivation) !void {
    try handler.validate(activation);
    try handler.effects.synchronize_active_resources(handler.effects.context);
    try handler.effects.schedule_host_input(handler.effects.context);
    try handler.effects.request_workspace_snapshot(
        handler.effects.context,
        activation.location.workspace,
    );
    try handler.effects.request_tab_snapshot(handler.effects.context, activation.location);
}

/// Rejects an activation that no longer proves the exact committed root,
/// one-step semantic transition and copy release. Compound flows may
/// validate before cleanup.
///
/// ```zig
/// try handler.validate(activation);
/// ```
pub fn validate(handler: *const ActivateWorkspaceHandler, activation: client_model.WorkspaceActivation) !void {
    const active = handler.model.workspace.activeConst() orelse return error.StaleWorkspaceActivation;
    const root = active.model.findConst(activation.pane_id) orelse return error.StaleWorkspaceActivation;
    const version = handler.model.version();
    if (!std.meta.eql(active.location, activation.location) or
        active.model.pane_count != 1 or
        active.model.layout.focused() != activation.pane_id or
        !std.meta.eql(root.location, activation.location) or
        !root.attached or
        version.workspace != activation.workspace_revision or
        version.tabs != activation.tabs_revision or
        version.active_tab != activation.active_tab_revision or
        version.panes != activation.panes_revision or
        version.copy != activation.copy_revision or
        activation.workspace_revision_before +% 1 != activation.workspace_revision or
        activation.tabs_revision_before +% 1 != activation.tabs_revision or
        activation.active_tab_revision_before +% 1 != activation.active_tab_revision or
        activation.panes_revision_before +% 1 != activation.panes_revision or
        activation.copy_revision_before +% @intFromBool(activation.copy_released) != activation.copy_revision)
    {
        return error.StaleWorkspaceActivation;
    }
}
