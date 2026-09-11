const Capture = @This();
const source_namespace = @import("tab_snapshot_recovery.zig");
const RequestTabSnapshotRecoveryHandler = @import("RequestTabSnapshotRecoveryHandler.zig");
is_pending: bool = false,
request_failure: ?anyerror = null,
events: [2]source_namespace.Event = undefined,
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

fn request(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .request = location });
    if (capture.request_failure) |failure| {
        return failure;
    }
}

fn append(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
