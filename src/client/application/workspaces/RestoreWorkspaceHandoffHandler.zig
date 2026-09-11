const WorkspaceHandoffRestorationEffects = @import("WorkspaceHandoffRestorationEffects.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("../tabs/RequestTabSnapshotRecoveryHandler.zig");
const ModelType = @import("../../model/Model.zig");
const workspace_handoff_restoration = @import("workspace_handoff_restoration.zig");
const RestoreWorkspaceHandoffHandler = @This();

effects: WorkspaceHandoffRestorationEffects,
snapshots: RequestTabSnapshotRecoveryHandlerType,

/// Restores active-pane graphics in captured order and requests one
/// canonical tab snapshot unless recovery is already pending.
///
/// ```zig
/// _ = try handler.execute(model);
/// ```
pub fn execute(handler: *RestoreWorkspaceHandoffHandler, model: *const ModelType) !workspace_handoff_restoration.Outcome {
    const location = model.activeTabLocation() orelse return .no_active_tab;
    const plan = try model.planTabDetachment(location);

    for (plan.slice()) |pane| {
        try handler.effects.show_pane_graphics(handler.effects.context, pane.pane_id);
    }

    return switch (try handler.snapshots.execute(location)) {
        .coalesced => .snapshot_coalesced,
        .requested => .snapshot_requested,
    };
}
