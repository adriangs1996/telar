const keybind = @import("keybind.zig");
const Control = @import("telar-client").Control;
const term = @import("../presentation/screen_support.zig");
const TerminalResponseCapture = @This();

forwarded: usize = 0,
responses: usize = 0,
actions: usize = 0,
supported: bool = false,

pub fn forward(capture: *TerminalResponseCapture, bytes: []const u8) !void {
    capture.forwarded += bytes.len;
}

pub fn action(capture: *TerminalResponseCapture, _: keybind.TestAction) !Control {
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
