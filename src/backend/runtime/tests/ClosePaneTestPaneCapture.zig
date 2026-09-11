const PaneCapture = @This();
const source_namespace = @import("close_pane_test.zig");
const close_pane_commands = @import("../application/commands/close_pane.zig");
attached_pane: source_namespace.schema.PaneId,
requested: bool = false,

pub fn port(capture: *PaneCapture) close_pane_commands.AttachedPaneCloser {
    return .{ .context = capture, .request_close = requestClose };
}

fn requestClose(context: *anyopaque, pane_id: source_namespace.schema.PaneId) ?bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));

    if (pane_id != capture.attached_pane) {
        return null;
    }

    const newly_requested = !capture.requested;
    capture.requested = true;
    return newly_requested;
}
