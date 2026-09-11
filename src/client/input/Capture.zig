const Capture = @This();
const source_namespace = @import("routing_tests.zig");
const input = @import("root.zig");
actions: [8]source_namespace.Action = undefined,
action_count: usize = 0,
keys: [8]input.Key = undefined,
key_count: usize = 0,

pub fn action(capture: *Capture, value: source_namespace.Action) !source_namespace.keybind.Control {
    capture.actions[capture.action_count] = value;
    capture.action_count += 1;
    return .continue_routing;
}

pub fn key(capture: *Capture, value: input.Key) !void {
    capture.keys[capture.key_count] = value;
    capture.key_count += 1;
}

pub fn forward(_: *Capture, _: []const u8) !void {
    return error.UnexpectedRawInput;
}
