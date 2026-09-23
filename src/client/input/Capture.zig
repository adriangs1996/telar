const model_data = @import("model");
const routing_tests = @import("routing_tests.zig");
const Capture = @This();

actions: [8]routing_tests.Action = undefined,
action_count: usize = 0,
keys: [8]model_data.Key = undefined,
key_count: usize = 0,

pub fn action(self: *Capture, value: routing_tests.Action) !model_data.KeybindControl {
    self.actions[self.action_count] = value;
    self.action_count += 1;
    return .continue_routing;
}

pub fn key(self: *Capture, value: model_data.Key) !void {
    self.keys[self.key_count] = value;
    self.key_count += 1;
}

pub fn forward(_: *Capture, _: []const u8) !void {
    return error.UnexpectedRawInput;
}

const GenericRouter = @import("GenericRouter.zig").Type;
const Router = GenericRouter(routing_tests.Action, .{ .max_bindings = 8, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 }, void);

pub fn apply(self: *Capture, decision: Router.Decision) !model_data.KeybindControl {
    switch (decision) {
        .forward => |value| try self.key(value.key),
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try self.key(held);
            }
            if (value.current_key) |current| {
                try self.key(current);
            }
        },
        .action => |request| return self.action(request.value),
        .pending, .discard => {},
    }
    return .continue_routing;
}
