const TabRemovedType = @import("../../workspace/TabRemoved.zig");
const CloseTabEventPublisher = @import("../application/commands/CloseTabEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?TabRemovedType = null,

pub fn publisher(capture: *EventCapture) CloseTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabRemovedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
