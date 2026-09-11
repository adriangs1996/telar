const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const RenameTabOperationGate = @import("RenameTabOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const TabRenameIntent = @import("TabRenameIntent.zig");
const RequestCapture = @This();

blocked: bool = false,
failure: ?anyerror = null,
calls: usize = 0,
location: ?TabLocationType = null,
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8 = 0,

pub fn gate(capture: *RequestCapture) RenameTabOperationGate {
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
