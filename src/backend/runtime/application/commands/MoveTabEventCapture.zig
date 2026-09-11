const ReaderType = @import("../../../workspace/Reader.zig");
const TabMovedType = @import("../../../workspace/TabMoved.zig");
const MoveTabEventPublisher = @import("MoveTabEventPublisher.zig");
const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const TabDescriptorType = @import("telar-core").TabDescriptor;
const EventCapture = @This();

reader: ReaderType,
count: usize = 0,
last: ?TabMovedType = null,
observed_committed_position: bool = false,

pub fn publisher(capture: *EventCapture) MoveTabEventPublisher {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, event: TabMovedType) void {
    const capture: *EventCapture = @ptrCast(@alignCast(context));
    var storage: [max_tabs_per_workspace_module]TabDescriptorType = undefined;
    const snapshot = capture.reader.descriptors(event.location.workspace, &storage) orelse return;

    capture.count += 1;
    capture.last = event;
    capture.observed_committed_position = snapshot.tabs[event.position].tab_id == event.location.tab_id;
}
