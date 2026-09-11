const ExitCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("close_pane.zig");
const PaneExitEffects = @import("PaneExitEffects.zig");
model: *const client_model.Model,
pane_id: source_namespace.schema.PaneId,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *ExitCapture) PaneExitEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, transition: source_namespace.PaneExit) !void {
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
