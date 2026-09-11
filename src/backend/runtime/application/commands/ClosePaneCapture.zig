const PaneIdType = @import("telar-core").PaneId;
const AttachedPaneCloser = @import("AttachedPaneCloser.zig");
const PaneCapture = @This();

result: ?bool,
call_count: usize = 0,
last_pane_id: PaneIdType = .invalid,

pub fn port(capture: *PaneCapture) AttachedPaneCloser {
    return .{ .context = capture, .request_close = requestClose };
}

fn requestClose(context: *anyopaque, pane_id: PaneIdType) ?bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_pane_id = pane_id;
    return capture.result;
}
