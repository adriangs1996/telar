const Capture = @This();
const source_namespace = @import("native_action.zig");
const Effects = @import("NativeActionEffects.zig");
events: [2]source_namespace.Event = undefined,
event_count: usize = 0,
delivered: ?source_namespace.Action = null,
control: source_namespace.Control = .continue_routing,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .leave_copy_mode = leaveCopyMode,
        .deliver = deliver,
    };
}

fn leaveCopyMode(raw_context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.leave_copy_mode);

    if (capture.failure == .leave_copy_mode) {
        return error.CopyModeLeaveFailed;
    }
}

fn deliver(raw_context: *anyopaque, value: source_namespace.Action) !source_namespace.Control {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.deliver);
    capture.delivered = value;

    if (capture.failure == .deliver) {
        return error.NativeActionDeliveryFailed;
    }

    return capture.control;
}

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
