const SelectionCapture = @This();
const source_namespace = @import("workspace_handoff.zig");
const SelectionGate = @import("SelectionGate.zig");
const SelectionEffects = @import("SelectionEffects.zig");
blocked: bool = false,
fail: bool = false,
calls: usize = 0,
requested: ?source_namespace.schema.WorkspaceId = null,

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

fn request(context: *anyopaque, workspace: source_namespace.schema.WorkspaceId) !void {
    const capture: *SelectionCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.requested = workspace;
    if (capture.fail) {
        return error.SelectionDeliveryFailed;
    }
}
