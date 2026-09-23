const data = @import("model");
const keybind = @import("keybind.zig");
const SemanticCapture = @This();

keys: [128]data.Key = undefined,
key_count: usize = 0,
action_count: usize = 0,
fail_key: bool = false,
fail_action: bool = false,
repeat_policy: ?data.RepeatPolicy = null,

pub fn repeatPolicy(self: *const SemanticCapture, value: keybind.TestAction) ?data.RepeatPolicy {
    return if (value == .next) self.repeat_policy else null;
}

pub fn key(self: *SemanticCapture, value: data.Key) !void {
    if (self.fail_key) {
        return error.KeyDeliveryFailed;
    }

    self.keys[self.key_count] = value;
    self.key_count += 1;
}

pub fn forward(_: *SemanticCapture, _: []const u8) !void {}

pub fn action(self: *SemanticCapture, _: keybind.TestAction) !data.KeybindControl {
    if (self.fail_action) {
        return error.ActionFailed;
    }

    self.action_count += 1;

    return .continue_routing;
}
