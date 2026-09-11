const ModelType = @import("../../model/Model.zig");
const WorkspaceSnapshotEffects = @import("WorkspaceSnapshotEffects.zig");
const WorkspaceReconciliationType = @import("../../model/WorkspaceReconciliation.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
removed_tabs: usize = 0,
removed_panes: usize = 0,
active_changed: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) WorkspaceSnapshotEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, reconciliation: *const WorkspaceReconciliationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const version = capture.model.version();
    capture.calls += 1;
    capture.removed_tabs = reconciliation.removed_tabs.slice().len;
    capture.removed_panes = reconciliation.removed_panes.slice().len;
    capture.active_changed = reconciliation.active_tab_changed;
    capture.observed_commit = std.mem.eql(u8, capture.model.workspace.workspaceName(), "renamed") and
        capture.model.workspace.count == 1 and
        version.workspace == reconciliation.workspace_revision and
        version.tabs == reconciliation.tabs_revision and
        version.active_tab == reconciliation.active_tab_revision and
        version.panes == reconciliation.panes_revision;

    if (capture.fail) {
        return error.ReconciliationSyncFailed;
    }
}
