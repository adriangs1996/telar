const RequestCapture = @This();
const source_namespace = @import("close_pane.zig");
const PaneOperationGate = @import("ClosePanePaneOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
blocked: bool = false,
calls: usize = 0,
closure: ?source_namespace.PaneClosure = null,
fail: bool = false,

pub fn gate(capture: *RequestCapture) PaneOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *RequestCapture) CloseRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, closure: source_namespace.PaneClosure) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.closure = closure;
    if (capture.fail) {
        return error.SendFailed;
    }
}
