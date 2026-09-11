const EventCapture = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const EventPublisher = @import("CloseTabEventPublisher.zig");
reader: workspace_mod.Reader,
pane_close_count: *const usize,
count: usize = 0,
last: ?workspace_mod.TabRemoved = null,
observed_committed_state: bool = false,
observed_closed_panes: bool = false,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabRemoved) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const workspace_exists = capture.reader.containsWorkspace(event.location.workspace);

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = !capture.reader.contains(event.location) and
        (if (event.workspace_removed) !workspace_exists else workspace_exists);
    capture.observed_closed_panes = capture.pane_close_count.* == 1;
}
