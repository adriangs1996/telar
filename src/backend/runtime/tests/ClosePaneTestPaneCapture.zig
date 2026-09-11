const PaneIdType = @import("telar-core").PaneId;
const AttachedPaneCloserType = @import("../application/commands/AttachedPaneCloser.zig");
const PaneCapture = @This();

attached_pane: PaneIdType,
requested: bool = false,

pub fn port(capture: *PaneCapture) AttachedPaneCloserType {
    return .{ .context = capture, .request_close = requestClose };
}

fn requestClose(context: *anyopaque, pane_id: PaneIdType) ?bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));

    if (pane_id != capture.attached_pane) {
        return null;
    }

    const newly_requested = !capture.requested;
    capture.requested = true;
    return newly_requested;
}
