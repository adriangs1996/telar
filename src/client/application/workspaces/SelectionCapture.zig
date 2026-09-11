const WorkspaceIdType = @import("telar-core").WorkspaceId;
const SelectionGate = @import("SelectionGate.zig");
const SelectionEffects = @import("SelectionEffects.zig");
const SelectionCapture = @This();

blocked: bool = false,
fail: bool = false,
calls: usize = 0,
requested: ?WorkspaceIdType = null,

pub fn gate(capture: *SelectionCapture) SelectionGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *SelectionCapture) SelectionEffects {
    return .{ .context = capture, .request = request };
}

fn pending(context: *anyopaque) bool {
    const capture: *SelectionCapture = @ptrCast(@alignCast(context));

    return capture.blocked;
}

fn request(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const capture: *SelectionCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.requested = workspace;
    if (capture.fail) {
        return error.SelectionDeliveryFailed;
    }
}
