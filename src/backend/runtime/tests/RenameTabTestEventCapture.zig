const TabRenamedType = @import("../../workspace/TabRenamed.zig");
const RenameTabEventPublisher = @import("../application/commands/RenameTabEventPublisher.zig");
const EventCapture = @This();

count: usize = 0,
last: ?TabRenamedType = null,

pub fn publisher(capture: *EventCapture) RenameTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabRenamedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.last = event;
}
