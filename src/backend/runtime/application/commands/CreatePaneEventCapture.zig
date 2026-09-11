const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const CreatePaneEventPublisher = @import("CreatePaneEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?PaneLaunchedType = null,

pub fn publisher(capture: *EventCapture) CreatePaneEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, launched: PaneLaunchedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = launched;
}
