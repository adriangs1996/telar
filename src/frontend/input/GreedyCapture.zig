const keyinput = @import("keyinput");
const keybind = @import("keybind.zig");
const GreedyCapture = @This();

keys: [8]keyinput.Key = undefined,
key_count: usize = 0,
action_count: usize = 0,

pub fn capturesKeys(_: *const GreedyCapture) bool {
    return true;
}

pub fn key(self: *GreedyCapture, value: keyinput.Key) !void {
    self.keys[self.key_count] = value;
    self.key_count += 1;
}

pub fn forward(_: *GreedyCapture, _: []const u8) !void {}

pub fn action(self: *GreedyCapture, _: keybind.TestAction) !keyinput.Control {
    self.action_count += 1;
    return .continue_routing;
}
