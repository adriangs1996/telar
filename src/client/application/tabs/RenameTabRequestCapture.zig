const RequestCapture = @This();
const source_namespace = @import("rename_tab.zig");
const TabOperationGate = @import("RenameTabTabOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const TabRenameIntent = @import("TabRenameIntent.zig");
blocked: bool = false,
failure: ?anyerror = null,
calls: usize = 0,
location: ?source_namespace.schema.TabLocation = null,
label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
label_len: u8 = 0,

pub fn gate(capture: *RequestCapture) TabOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn effects(capture: *RequestCapture) RenameRequestEffects {
    return .{ .context = capture, .send = send };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn send(context: *anyopaque, requested: TabRenameIntent) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.location = requested.location;
    capture.label_len = @intCast(requested.label.len);
    @memcpy(capture.label[0..requested.label.len], requested.label);

    if (capture.failure) |failure| {
        return failure;
    }
}

pub fn labelSlice(capture: *const RequestCapture) []const u8 {
    return capture.label[0..capture.label_len];
}
