const ReaderType = @import("../../../workspace/Reader.zig");
const TabRenamedType = @import("../../../workspace/TabRenamed.zig");
const RenameTabEventPublisher = @import("RenameTabEventPublisher.zig");
const std = @import("std");
const EventCapture = @This();

reader: ReaderType,
count: usize = 0,
last: ?TabRenamedType = null,
observed_committed_state: bool = false,

pub fn publisher(capture: *EventCapture) RenameTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabRenamedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const committed_label = capture.reader.tabLabel(event.location) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = std.mem.eql(u8, committed_label, event.labelSlice());
}
