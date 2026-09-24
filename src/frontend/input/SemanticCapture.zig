const keyinput = @import("keyinput");
const keybind = @import("keybind.zig");
const SemanticCapture = @This();

keys: [128]keyinput.Key = undefined,
key_count: usize = 0,
action_count: usize = 0,
fail_key: bool = false,
fail_action: bool = false,
repeat_policy: ?keyinput.RepeatPolicy = null,

pub fn repeatPolicy(self: *const SemanticCapture, value: keybind.TestAction) ?keyinput.RepeatPolicy {
    return if (value == .next) self.repeat_policy else null;
}

pub fn key(self: *SemanticCapture, value: keyinput.Key) !void {
    if (self.fail_key) {
        return error.KeyDeliveryFailed;
    }

    self.keys[self.key_count] = value;
    self.key_count += 1;
}

pub fn forward(_: *SemanticCapture, _: []const u8) !void {}

pub fn action(self: *SemanticCapture, _: keybind.TestAction) !keyinput.Control {
    if (self.fail_action) {
        return error.ActionFailed;
    }

    self.action_count += 1;

    return .continue_routing;
}
