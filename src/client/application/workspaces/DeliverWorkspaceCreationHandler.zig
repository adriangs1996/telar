const ModelType = @import("../../model/Model.zig");
const ReleaseEffectsType = @import("ReleaseEffects.zig");
const ActivationEffectsType = @import("ActivationEffects.zig");
const WorkspaceReplacementType = @import("../../model/WorkspaceReplacement.zig");
const ActivateWorkspaceHandlerType = @import("ActivateWorkspaceHandler.zig");
const ReleaseWorkspaceResourcesHandlerType = @import("ReleaseWorkspaceResourcesHandler.zig");
const std = @import("std");
const workspace_creation_delivery = @import("workspace_creation_delivery.zig");
const DeliverWorkspaceCreationHandler = @This();

model: *ModelType,
release_effects: ReleaseEffectsType,
activation_effects: ActivationEffectsType,

/// Validates an exact replacement before releasing its departed resources
/// and activating the runtime-created root.
///
/// ```zig
/// try handler.execute(&replacement);
/// ```
pub fn execute(handler: *DeliverWorkspaceCreationHandler, replacement: *const WorkspaceReplacementType) !void {
    var activate: ActivateWorkspaceHandlerType = .{
        .model = handler.model,
        .effects = handler.activation_effects,
    };
    try activate.validate(replacement.activation);
    try handler.validateDeparture(replacement);

    var release: ReleaseWorkspaceResourcesHandlerType = .{
        .model = handler.model,
        .effects = handler.release_effects,
    };
    release.execute(&replacement.departure);

    try activate.execute(replacement.activation);
}

fn validateDeparture(handler: *const DeliverWorkspaceCreationHandler, replacement: *const WorkspaceReplacementType) !void {
    const panes = replacement.departure.panes.slice();
    const source = replacement.departure.source orelse {
        if (replacement.departure.bookmark != null or panes.len != 0) {
            return error.StaleWorkspaceCreation;
        }
        return;
    };
    if (std.meta.eql(source, replacement.activation.location.workspace)) {
        return error.StaleWorkspaceCreation;
    }

    if (replacement.departure.bookmark) |bookmark| {
        if (!std.meta.eql(bookmark.location.workspace, source) or
            bookmark.tab_layout.focused() != bookmark.pane_id or
            !workspace_creation_delivery.containsPane(panes, bookmark.pane_id))
        {
            return error.StaleWorkspaceCreation;
        }
    }

    for (panes, 0..) |pane_id, index| {
        if (pane_id == .invalid or
            pane_id == replacement.activation.pane_id or
            handler.model.workspace.findPane(pane_id) != null)
        {
            return error.StaleWorkspaceCreation;
        }

        for (panes[0..index]) |previous| {
            if (previous == pane_id) {
                return error.StaleWorkspaceCreation;
            }
        }
    }
}
