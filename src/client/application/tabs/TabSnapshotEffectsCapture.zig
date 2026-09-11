const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabSnapshotEffects = @import("TabSnapshotEffects.zig");
const TabReconciliationType = @import("../../model/TabReconciliation.zig");
const EffectsCapture = @This();

model: *ModelType,
expected_pane: PaneIdType,
calls: usize = 0,
observed_commit: bool = false,
active: bool = false,
panes_changed: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) TabSnapshotEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, reconciliation: *const TabReconciliationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.active = reconciliation.active;
    capture.panes_changed = reconciliation.panes_changed;
    capture.observed_commit = capture.model.workspace.findPane(capture.expected_pane) != null and
        capture.model.version().workspace == reconciliation.workspace_revision and
        capture.model.version().tabs == reconciliation.tabs_revision and
        capture.model.version().active_tab == reconciliation.active_tab_revision and
        capture.model.version().panes == reconciliation.panes_revision;

    if (capture.fail) {
        return error.ReconciliationSyncFailed;
    }
}
