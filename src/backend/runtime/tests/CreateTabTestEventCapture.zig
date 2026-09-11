const TabCreatedType = @import("../../workspace/TabCreated.zig");
const CreateTabEventPublisher = @import("../application/commands/CreateTabEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?TabCreatedType = null,

pub fn publisher(capture: *EventCapture) CreateTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabCreatedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
