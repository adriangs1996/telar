const open_pane = @import("open_pane.zig");
const OpenPaneEventPublisher = @import("OpenPaneEventPublisher.zig");
const EventCapture = @This();

events: [2]open_pane.RuntimeEvent = undefined,
len: usize = 0,

pub fn publisher(capture: *EventCapture) OpenPaneEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: open_pane.RuntimeEvent) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.events[capture.len] = event;
    capture.len += 1;
}
