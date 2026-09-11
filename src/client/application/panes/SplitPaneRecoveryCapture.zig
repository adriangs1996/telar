const RecoveryCapture = @This();
const client_model = @import("../../root.zig").model;
const RecoveryEffects = @import("RecoveryEffects.zig");
calls: usize = 0,
resize_value: ?client_model.PaneResize = null,
fail: bool = false,

pub fn port(capture: *RecoveryCapture) RecoveryEffects {
    return .{ .context = capture, .resize = resize };
}

fn resize(context: *anyopaque, value: client_model.PaneResize) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.resize_value = value;
    if (capture.fail) {
        return error.ResizeFailed;
    }
}
