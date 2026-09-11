const Key = @import("telar-client").Key;
const RepeatPolicy = @import("telar-client").RepeatPolicy;
const keybind = @import("keybind.zig");
const Control = @import("telar-client").Control;
const SemanticCapture = @This();

keys: [128]Key = undefined,
key_count: usize = 0,
action_count: usize = 0,
fail_key: bool = false,
fail_action: bool = false,
repeat_policy: ?RepeatPolicy = null,

pub fn repeatPolicy(capture: *const SemanticCapture, value: keybind.TestAction) ?RepeatPolicy {
    return if (value == .next) capture.repeat_policy else null;
}

pub fn key(capture: *SemanticCapture, value: Key) !void {
    if (capture.fail_key) {
        return error.KeyDeliveryFailed;
    }

    capture.keys[capture.key_count] = value;
    capture.key_count += 1;
}

pub fn forward(_: *SemanticCapture, _: []const u8) !void {}

pub fn action(capture: *SemanticCapture, _: keybind.TestAction) !Control {
    if (capture.fail_action) {
        return error.ActionFailed;
    }

    capture.action_count += 1;

    return .continue_routing;
}
