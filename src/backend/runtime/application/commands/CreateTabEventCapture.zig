const ReaderType = @import("../../../workspace/Reader.zig");
const TabCreatedType = @import("../../../workspace/TabCreated.zig");
const CreateTabEventPublisher = @import("CreateTabEventPublisher.zig");
const std = @import("std");
const EventCapture = @This();

reader: ReaderType,
initial_revision: u64,
count: usize = 0,
last: ?TabCreatedType = null,
observed_committed_state: bool = false,

pub fn publisher(capture: *EventCapture) CreateTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabCreatedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const committed_label = capture.reader.tabLabel(event.location) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = capture.reader.revision() != capture.initial_revision and
        std.mem.eql(u8, committed_label, event.labelSlice());
}
