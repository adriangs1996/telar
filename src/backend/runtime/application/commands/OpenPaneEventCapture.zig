const EventCapture = @This();
const source_namespace = @import("open_pane.zig");
const EventPublisher = @import("OpenPaneEventPublisher.zig");
events: [2]source_namespace.RuntimeEvent = undefined,
len: usize = 0,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: source_namespace.RuntimeEvent) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.events[capture.len] = event;
    capture.len += 1;
}
