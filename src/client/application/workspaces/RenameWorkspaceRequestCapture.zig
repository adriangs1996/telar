const RequestCapture = @This();
const source_namespace = @import("rename_workspace.zig");
const WorkspaceOperationGate = @import("RenameWorkspaceWorkspaceOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const RequestedRename = @import("RequestedRename.zig");
blocked: bool = false,
failure: ?anyerror = null,
calls: usize = 0,
workspace: ?source_namespace.schema.WorkspaceLocation = null,
name: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
name_len: u8 = 0,

pub fn gate(capture: *RequestCapture) WorkspaceOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn effects(capture: *RequestCapture) RenameRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, requested: RequestedRename) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.workspace = requested.workspace;
    capture.name_len = @intCast(requested.name.len);
    @memcpy(capture.name[0..requested.name.len], requested.name);

    if (capture.failure) |failure| {
        return failure;
    }
}

pub fn nameSlice(capture: *const RequestCapture) []const u8 {
    return capture.name[0..capture.name_len];
}
