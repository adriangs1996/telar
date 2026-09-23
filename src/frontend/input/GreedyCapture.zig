const data = @import("model");
const keybind = @import("keybind.zig");
const GreedyCapture = @This();

keys: [8]data.Key = undefined,
key_count: usize = 0,
action_count: usize = 0,

pub fn capturesKeys(_: *const GreedyCapture) bool {
    return true;
}

pub fn key(self: *GreedyCapture, value: data.Key) !void {
    self.keys[self.key_count] = value;
    self.key_count += 1;
}

pub fn forward(_: *GreedyCapture, _: []const u8) !void {}

pub fn action(self: *GreedyCapture, _: keybind.TestAction) !data.KeybindControl {
    self.action_count += 1;
    return .continue_routing;
}
