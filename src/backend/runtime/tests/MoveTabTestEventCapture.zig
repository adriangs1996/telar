const TabMovedType = @import("../../workspace/TabMoved.zig");
const MoveTabEventPublisher = @import("../application/commands/MoveTabEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?TabMovedType = null,

pub fn publisher(capture: *EventCapture) MoveTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabMovedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
