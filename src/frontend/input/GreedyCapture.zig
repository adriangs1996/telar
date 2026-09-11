const Key = @import("telar-client").Key;
const keybind = @import("keybind.zig");
const Control = @import("telar-client").Control;
const GreedyCapture = @This();

keys: [8]Key = undefined,
key_count: usize = 0,
action_count: usize = 0,

pub fn capturesKeys(_: *const GreedyCapture) bool {
    return true;
}

pub fn key(capture: *GreedyCapture, value: Key) !void {
    capture.keys[capture.key_count] = value;
    capture.key_count += 1;
}

pub fn forward(_: *GreedyCapture, _: []const u8) !void {}

pub fn action(capture: *GreedyCapture, _: keybind.TestAction) !Control {
    capture.action_count += 1;
    return .continue_routing;
}
