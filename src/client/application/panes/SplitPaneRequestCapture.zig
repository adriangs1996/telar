const RequestCapture = @This();
const source_namespace = @import("split_pane.zig");
const client_model = @import("../../root.zig").model;
const PaneOperationGate = @import("SplitPanePaneOperationGate.zig");
const RequestEffects = @import("RequestEffects.zig");
blocked: bool = false,
send_failure: ?anyerror = null,
steps: [3]source_namespace.RequestStep = undefined,
step_count: u8 = 0,
resizes: [2]client_model.PaneResize = undefined,
resize_count: u8 = 0,

pub fn gate(capture: *RequestCapture) PaneOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *RequestCapture) RequestEffects {
    return .{ .context = capture, .resize = resize, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn resize(context: *anyopaque, value: client_model.PaneResize) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.steps[capture.step_count] = .resize;
    capture.step_count += 1;
    capture.resizes[capture.resize_count] = value;
    capture.resize_count += 1;
}

fn send(context: *anyopaque, _: client_model.PaneSplitPlan) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.steps[capture.step_count] = .send;
    capture.step_count += 1;
    if (capture.send_failure) |failure| {
        return failure;
    }
}

pub fn recorded(capture: *const RequestCapture) []const source_namespace.RequestStep {
    return capture.steps[0..capture.step_count];
}
