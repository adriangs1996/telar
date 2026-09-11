const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_snapshot.zig");
const Effects = @import("TabSnapshotEffects.zig");
model: *client_model.Model,
expected_pane: source_namespace.schema.PaneId,
calls: usize = 0,
observed_commit: bool = false,
active: bool = false,
panes_changed: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
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
