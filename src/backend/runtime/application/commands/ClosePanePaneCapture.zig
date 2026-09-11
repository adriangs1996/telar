const PaneCapture = @This();
const source_namespace = @import("close_pane.zig");
const AttachedPaneCloser = @import("AttachedPaneCloser.zig");
result: ?bool,
call_count: usize = 0,
last_pane_id: source_namespace.schema.PaneId = .invalid,

pub fn port(capture: *PaneCapture) AttachedPaneCloser {
    return .{ .context = capture, .request_close = requestClose };
}

fn requestClose(context: *anyopaque, pane_id: source_namespace.schema.PaneId) ?bool {
    const capture: *PaneCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_pane_id = pane_id;
    return capture.result;
}
