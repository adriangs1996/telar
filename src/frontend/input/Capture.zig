const keyinput = @import("keyinput");
const keybind = @import("keybind.zig");
const Capture = @This();

bytes: [256]u8 = undefined,
len: usize = 0,
actions: [8]keybind.TestAction = undefined,
action_len: usize = 0,
stop_on_action: bool = false,

pub fn forward(self: *Capture, bytes: []const u8) !void {
    if (self.len + bytes.len > self.bytes.len) {
        return error.CaptureOverflow;
    }
    @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

pub fn action(self: *Capture, value: keybind.TestAction) !keyinput.Control {
    self.actions[self.action_len] = value;
    self.action_len += 1;
    return if (self.stop_on_action) .stop else .continue_routing;
}

pub fn slice(self: *const Capture) []const u8 {
    return self.bytes[0..self.len];
}
