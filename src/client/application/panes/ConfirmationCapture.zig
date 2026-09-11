const ConfirmationCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("split_pane.zig");
const ConfirmationEffects = @import("ConfirmationEffects.zig");
model: *const client_model.Model,
pane_id: source_namespace.schema.PaneId,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ConfirmationCapture) ConfirmationEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, commit: client_model.PaneSplitCommit) !void {
    const capture: *ConfirmationCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.workspace.activeConst().?.model.findConst(capture.pane_id) != null and
        capture.model.version().panes == commit.panes_revision and
        commit.pane_id == capture.pane_id;
    if (capture.fail) {
        return error.SyncFailed;
    }
}
