const GateCapture = @This();
const Gate = @import("Gate.zig");
blocked: bool = false,
calls: usize = 0,

pub fn gate(capture: *GateCapture) Gate {
    return .{ .context = capture, .pending = pending };
}

fn pending(context: *anyopaque) bool {
    const capture: *GateCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;

    return capture.blocked;
}
