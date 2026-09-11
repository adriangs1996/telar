const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const RenameWorkspaceOperationGate = @import("RenameWorkspaceOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const RequestedRename = @import("RequestedRename.zig");
const RequestCapture = @This();

blocked: bool = false,
failure: ?anyerror = null,
calls: usize = 0,
workspace: ?WorkspaceLocationType = null,
name: [max_tab_label_bytes_module]u8 = undefined,
name_len: u8 = 0,

pub fn gate(capture: *RequestCapture) RenameWorkspaceOperationGate {
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
