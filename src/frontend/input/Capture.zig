const Capture = @This();
const source_namespace = @import("keybind.zig");
const Control = @import("telar-client").input.keybind.Control;
bytes: [256]u8 = undefined,
len: usize = 0,
actions: [8]source_namespace.TestAction = undefined,
action_len: usize = 0,
stop_on_action: bool = false,

pub fn forward(capture: *Capture, bytes: []const u8) !void {
    if (capture.len + bytes.len > capture.bytes.len) {
        return error.CaptureOverflow;
    }
    @memcpy(capture.bytes[capture.len..][0..bytes.len], bytes);
    capture.len += bytes.len;
}

pub fn action(capture: *Capture, value: source_namespace.TestAction) !Control {
    capture.actions[capture.action_len] = value;
    capture.action_len += 1;
    return if (capture.stop_on_action) .stop else .continue_routing;
}

pub fn slice(capture: *const Capture) []const u8 {
    return capture.bytes[0..capture.len];
}
