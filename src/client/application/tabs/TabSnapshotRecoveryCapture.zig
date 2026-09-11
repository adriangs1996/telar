const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");
const RequestTabSnapshotRecoveryHandler = @import("RequestTabSnapshotRecoveryHandler.zig");
const TabLocationType = @import("telar-core").TabLocation;
const Capture = @This();

is_pending: bool = false,
request_failure: ?anyerror = null,
events: [2]tab_snapshot_recovery.Event = undefined,
event_count: usize = 0,

pub fn handler(capture: *Capture) RequestTabSnapshotRecoveryHandler {
    return .{ .effects = .{
        .context = capture,
        .pending = pending,
        .request = request,
    } };
}

fn pending(context: *anyopaque) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.pending);

    return capture.is_pending;
}

fn request(context: *anyopaque, location: TabLocationType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .request = location });
    if (capture.request_failure) |failure| {
        return failure;
    }
}

fn append(capture: *Capture, event: tab_snapshot_recovery.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const tab_snapshot_recovery.Event {
    return capture.events[0..capture.event_count];
}
