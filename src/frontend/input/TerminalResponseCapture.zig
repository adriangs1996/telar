const console = @import("console");
const keyinput = @import("keyinput");
const keybind = @import("keybind.zig");
const TerminalResponseCapture = @This();

forwarded: usize = 0,
responses: usize = 0,
actions: usize = 0,
supported: bool = false,

pub fn forward(self: *TerminalResponseCapture, bytes: []const u8) !void {
    self.forwarded += bytes.len;
}

pub fn action(self: *TerminalResponseCapture, _: keybind.TestAction) !keyinput.Control {
    self.actions += 1;
    return .continue_routing;
}

pub fn terminalResponse(self: *TerminalResponseCapture, response: console.Event.TerminalResponse) !void {
    switch (response) {
        .kitty_graphics => |kitty| self.supported = kitty.supported,
        else => {},
    }
    self.responses += 1;
}
