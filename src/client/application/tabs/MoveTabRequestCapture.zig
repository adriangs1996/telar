const TabMoveIntent = @import("TabMoveIntent.zig");
const MoveTabOperationGate = @import("MoveTabOperationGate.zig");
const MoveRequestEffects = @import("MoveRequestEffects.zig");
const RequestCapture = @This();

blocked: bool = false,
fail: bool = false,
calls: usize = 0,
intent: ?TabMoveIntent = null,

pub fn gate(capture: *RequestCapture) MoveTabOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn effects(capture: *RequestCapture) MoveRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, intent: TabMoveIntent) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.intent = intent;

    if (capture.fail) {
        return error.DeliveryFailed;
    }
}
