const MouseCapture = @This();
const source_namespace = @import("keybind.zig");
const Control = @import("telar-client").input.keybind.Control;
const term = @import("../presentation/root.zig").screen;
forwarded: usize = 0,
mouse_events: usize = 0,

pub fn forward(capture: *MouseCapture, bytes: []const u8) !void {
    capture.forwarded += bytes.len;
}

pub fn action(_: *MouseCapture, _: source_namespace.TestAction) !Control {
    return .continue_routing;
}

pub fn mouse(capture: *MouseCapture, _: term.Event.Mouse) !void {
    capture.mouse_events += 1;
}
