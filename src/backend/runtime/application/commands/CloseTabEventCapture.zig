const ReaderType = @import("../../../workspace/Reader.zig");
const TabRemovedType = @import("../../../workspace/TabRemoved.zig");
const CloseTabEventPublisher = @import("CloseTabEventPublisher.zig");
const EventCapture = @This();

reader: ReaderType,
pane_close_count: *const usize,
count: usize = 0,
last: ?TabRemovedType = null,
observed_committed_state: bool = false,
observed_closed_panes: bool = false,

pub fn publisher(capture: *EventCapture) CloseTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabRemovedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const workspace_exists = capture.reader.containsWorkspace(event.location.workspace);

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = !capture.reader.contains(event.location) and
        (if (event.workspace_removed) !workspace_exists else workspace_exists);
    capture.observed_closed_panes = capture.pane_close_count.* == 1;
}
