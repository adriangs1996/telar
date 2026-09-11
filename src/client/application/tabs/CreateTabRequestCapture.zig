const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneIdType = @import("telar-core").PaneId;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const CreateTabOperationGate = @import("CreateTabOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const TabCreationIntent = @import("TabCreationIntent.zig");
const RequestCapture = @This();

blocked: bool = false,
fail: bool = false,
calls: usize = 0,
workspace: ?WorkspaceLocationType = null,
cwd_source: ?PaneIdType = null,
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8 = 0,

pub fn gate(capture: *RequestCapture) CreateTabOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn effects(capture: *RequestCapture) CreationRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, intent: TabCreationIntent) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.workspace = intent.workspace;
    capture.cwd_source = intent.cwd_source;
    capture.label_len = @intCast(intent.label.len);
    @memcpy(capture.label[0..intent.label.len], intent.label);

    if (capture.fail) {
        return error.DeliveryFailed;
    }
}

pub fn labelSlice(capture: *const RequestCapture) []const u8 {
    return capture.label[0..capture.label_len];
}
