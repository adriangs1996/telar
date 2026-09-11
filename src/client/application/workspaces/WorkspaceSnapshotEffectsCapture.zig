const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("WorkspaceSnapshotEffects.zig");
const std = @import("std");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
removed_tabs: usize = 0,
removed_panes: usize = 0,
active_changed: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, reconciliation: *const client_model.WorkspaceReconciliation) !void {
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
