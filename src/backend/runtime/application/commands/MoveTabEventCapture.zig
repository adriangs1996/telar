const EventCapture = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const EventPublisher = @import("MoveTabEventPublisher.zig");
const source_namespace = @import("move_tab.zig");
reader: workspace_mod.Reader,
count: usize = 0,
last: ?workspace_mod.TabMoved = null,
observed_committed_position: bool = false,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabMoved) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    var storage: [workspace_mod.max_tabs_per_workspace]source_namespace.schema.TabDescriptor = undefined;
    const snapshot = capture.reader.descriptors(event.location.workspace, &storage) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_position = snapshot.tabs[event.position].tab_id == event.location.tab_id;
}
