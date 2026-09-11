const TerminalResponseCapture = @This();
const source_namespace = @import("keybind.zig");
const Control = @import("telar-client").input.keybind.Control;
const term = @import("../presentation/root.zig").screen;
forwarded: usize = 0,
responses: usize = 0,
actions: usize = 0,
supported: bool = false,

pub fn forward(capture: *TerminalResponseCapture, bytes: []const u8) !void {
    capture.forwarded += bytes.len;
}

pub fn action(capture: *TerminalResponseCapture, _: source_namespace.TestAction) !Control {
    capture.actions += 1;
    return .continue_routing;
}

pub fn terminalResponse(capture: *TerminalResponseCapture, response: term.Event.TerminalResponse) !void {
    switch (response) {
        .kitty_graphics => |kitty| capture.supported = kitty.supported,
        else => {},
    }
    capture.responses += 1;
}
