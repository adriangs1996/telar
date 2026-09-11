const PaneClosureType = @import("../../model/PaneClosure.zig");
const ClosePaneOperationGate = @import("ClosePaneOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const RequestCapture = @This();

blocked: bool = false,
calls: usize = 0,
closure: ?PaneClosureType = null,
fail: bool = false,

pub fn gate(capture: *RequestCapture) ClosePaneOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *RequestCapture) CloseRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, closure: PaneClosureType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.closure = closure;
    if (capture.fail) {
        return error.SendFailed;
    }
}
