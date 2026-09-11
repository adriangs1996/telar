const PaneResizeType = @import("telar-core").PaneResize;
const RecoveryEffects = @import("RecoveryEffects.zig");
const RecoveryCapture = @This();

calls: usize = 0,
resize_value: ?PaneResizeType = null,
fail: bool = false,

pub fn port(capture: *RecoveryCapture) RecoveryEffects {
    return .{ .context = capture, .resize = resize };
}

fn resize(context: *anyopaque, value: PaneResizeType) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.resize_value = value;
    if (capture.fail) {
        return error.ResizeFailed;
    }
}
