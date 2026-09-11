const RestoreWorkspaceHandoffHandler = @This();
const Effects = @import("WorkspaceHandoffRestorationEffects.zig");
const tab_snapshot_recovery = @import("../tabs/root.zig").tab_snapshot_recovery;
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_handoff_restoration.zig");
effects: Effects,
snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

/// Restores active-pane graphics in captured order and requests one
/// canonical tab snapshot unless recovery is already pending.
///
/// ```zig
/// _ = try handler.execute(model);
/// ```
pub fn execute(handler: *RestoreWorkspaceHandoffHandler, model: *const client_model.Model) !source_namespace.Outcome {
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
