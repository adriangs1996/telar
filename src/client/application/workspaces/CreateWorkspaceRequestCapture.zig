const PaneIdType = @import("telar-core").PaneId;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const CreateWorkspaceOperationGate = @import("CreateWorkspaceOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const WorkspaceCreation = @import("WorkspaceCreation.zig");
const RequestCapture = @This();

blocked: bool = false,
fail: bool = false,
calls: usize = 0,
source: ?PaneIdType = null,
name: [max_tab_label_bytes_module]u8 = undefined,
name_len: u8 = 0,
cwd: [max_cwd_bytes_module]u8 = undefined,
cwd_len: u16 = 0,
create_cwd: bool = false,

pub fn gate(capture: *RequestCapture) CreateWorkspaceOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn effects(capture: *RequestCapture) CreationRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, creation: WorkspaceCreation) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.source = creation.cwd_source;
    capture.name_len = @intCast(creation.name.len);
    @memcpy(capture.name[0..creation.name.len], creation.name);
    capture.cwd_len = @intCast(creation.cwd.len);
    @memcpy(capture.cwd[0..creation.cwd.len], creation.cwd);
    capture.create_cwd = creation.create_cwd;

    if (capture.fail) {
        return error.DeliveryFailed;
    }
}

pub fn nameSlice(capture: *const RequestCapture) []const u8 {
    return capture.name[0..capture.name_len];
}

pub fn cwdSlice(capture: *const RequestCapture) []const u8 {
    return capture.cwd[0..capture.cwd_len];
}
