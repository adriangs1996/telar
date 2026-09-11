const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const ConfirmationEffects = @import("ConfirmationEffects.zig");
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const ConfirmationCapture = @This();

model: *const ModelType,
pane_id: PaneIdType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ConfirmationCapture) ConfirmationEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, commit: PaneSplitCommitType) !void {
    const capture: *ConfirmationCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.workspace.activeConst().?.model.findConst(capture.pane_id) != null and
        capture.model.version().panes == commit.panes_revision and
        commit.pane_id == capture.pane_id;
    if (capture.fail) {
        return error.SyncFailed;
    }
}
