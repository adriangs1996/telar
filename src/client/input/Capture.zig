const routing_tests = @import("routing_tests.zig");
const KeyType = @import("Key.zig");
const keybind_module = @import("keybind.zig");
const Capture = @This();

actions: [8]routing_tests.Action = undefined,
action_count: usize = 0,
keys: [8]KeyType = undefined,
key_count: usize = 0,

pub fn action(capture: *Capture, value: routing_tests.Action) !keybind_module.Control {
    capture.actions[capture.action_count] = value;
    capture.action_count += 1;
    return .continue_routing;
}

pub fn key(capture: *Capture, value: KeyType) !void {
    capture.keys[capture.key_count] = value;
    capture.key_count += 1;
}

pub fn forward(_: *Capture, _: []const u8) !void {
    return error.UnexpectedRawInput;
}
