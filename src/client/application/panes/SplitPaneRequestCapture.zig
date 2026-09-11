const split_pane = @import("split_pane.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const SplitPaneOperationGate = @import("SplitPaneOperationGate.zig");
const RequestEffects = @import("RequestEffects.zig");
const PaneSplitPlanType = @import("../../model/PaneSplitPlan.zig");
const RequestCapture = @This();

blocked: bool = false,
send_failure: ?anyerror = null,
steps: [3]split_pane.RequestStep = undefined,
step_count: u8 = 0,
resizes: [2]PaneResizeType = undefined,
resize_count: u8 = 0,

pub fn gate(capture: *RequestCapture) SplitPaneOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *RequestCapture) RequestEffects {
    return .{ .context = capture, .resize = resize, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn resize(context: *anyopaque, value: PaneResizeType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.steps[capture.step_count] = .resize;
    capture.step_count += 1;
    capture.resizes[capture.resize_count] = value;
    capture.resize_count += 1;
}

fn send(context: *anyopaque, _: PaneSplitPlanType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.steps[capture.step_count] = .send;
    capture.step_count += 1;
    if (capture.send_failure) |failure| {
        return failure;
    }
}

pub fn recorded(capture: *const RequestCapture) []const split_pane.RequestStep {
    return capture.steps[0..capture.step_count];
}
