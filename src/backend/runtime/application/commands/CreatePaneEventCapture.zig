const EventCapture = @This();
const pane_mod = @import("../../../pane/root.zig");
const EventPublisher = @import("CreatePaneEventPublisher.zig");
count: usize = 0,
last: ?pane_mod.PaneLaunched = null,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, launched: pane_mod.PaneLaunched) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = launched;
}
