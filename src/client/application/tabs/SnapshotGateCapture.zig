const SnapshotGate = @import("SnapshotGate.zig");
const SnapshotGateCapture = @This();

blocked: bool = false,

pub fn port(capture: *SnapshotGateCapture) SnapshotGate {
    return .{ .context = capture, .pending = pending };
}

fn pending(context: *anyopaque) bool {
    const capture: *SnapshotGateCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}
