const EventCapture = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const EventPublisher = @import("CreateTabEventPublisher.zig");
const std = @import("std");
reader: workspace_mod.Reader,
initial_revision: u64,
count: usize = 0,
last: ?workspace_mod.TabCreated = null,
observed_committed_state: bool = false,

pub fn publisher(capture: *EventCapture) EventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: workspace_mod.TabCreated) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    const committed_label = capture.reader.tabLabel(event.location) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_state = capture.reader.revision() != capture.initial_revision and
        std.mem.eql(u8, committed_label, event.labelSlice());
}
