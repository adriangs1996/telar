const keyinput = @import("keyinput");
const keybind = @import("keybind.zig");
const MouseCapture = @This();

forwarded: usize = 0,
mouse_events: usize = 0,

pub fn forward(self: *MouseCapture, bytes: []const u8) !void {
    self.forwarded += bytes.len;
}

pub fn action(_: *MouseCapture, _: keybind.TestAction) !keyinput.Control {
    return .continue_routing;
}

pub fn mouse(self: *MouseCapture, _: keyinput.Mouse) !void {
    self.mouse_events += 1;
}
