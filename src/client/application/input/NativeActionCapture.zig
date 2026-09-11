const native_action = @import("native_action.zig");
const action = @import("../../input/action.zig");
const action_routing = @import("action_routing.zig");
const NativeActionEffects = @import("NativeActionEffects.zig");
const Capture = @This();

events: [2]native_action.Event = undefined,
event_count: usize = 0,
delivered: ?action.Action = null,
control: action_routing.Control = .continue_routing,
failure: native_action.Failure = .none,

pub fn effects(capture: *Capture) NativeActionEffects {
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

fn deliver(raw_context: *anyopaque, value: action.Action) !action_routing.Control {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.deliver);
    capture.delivered = value;

    if (capture.failure == .deliver) {
        return error.NativeActionDeliveryFailed;
    }

    return capture.control;
}

fn record(capture: *Capture, event: native_action.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const native_action.Event {
    return capture.events[0..capture.event_count];
}
