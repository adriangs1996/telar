const RequestCapture = @This();
const source_namespace = @import("create_tab.zig");
const TabOperationGate = @import("CreateTabTabOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const TabCreationIntent = @import("TabCreationIntent.zig");
blocked: bool = false,
fail: bool = false,
calls: usize = 0,
workspace: ?source_namespace.schema.WorkspaceLocation = null,
cwd_source: ?source_namespace.schema.PaneId = null,
label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
label_len: u8 = 0,

pub fn gate(capture: *RequestCapture) TabOperationGate {
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
