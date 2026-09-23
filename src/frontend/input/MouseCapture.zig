const data = @import("model");
const keybind = @import("keybind.zig");
const term = @import("../presentation/screen_support.zig");
const MouseCapture = @This();

forwarded: usize = 0,
mouse_events: usize = 0,

pub fn forward(self: *MouseCapture, bytes: []const u8) !void {
    self.forwarded += bytes.len;
}

pub fn action(_: *MouseCapture, _: keybind.TestAction) !data.KeybindControl {
    return .continue_routing;
}

pub fn mouse(self: *MouseCapture, _: term.Event.Mouse) !void {
    self.mouse_events += 1;
}
