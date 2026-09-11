const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneExitEffects = @import("PaneExitEffects.zig");
const types = @import("../../model/types.zig");
const ExitCapture = @This();

model: *const ModelType,
pane_id: PaneIdType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ExitCapture) PaneExitEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, transition: types.PaneExit) !void {
    const capture: *ExitCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.workspace.activeConst().?.model.findConst(capture.pane_id) == null;
    switch (transition) {
        .retired => |retired| {
            capture.observed_commit = capture.observed_commit and
                retired.pane_id == capture.pane_id and
                capture.model.version().panes == 1;
        },
        .stale => |stale| {
            capture.observed_commit = capture.observed_commit and stale.pane_id == capture.pane_id;
        },
    }

    if (capture.fail) {
        return error.CleanupFailed;
    }
}
