const Control = @import("Control.zig").Control;
const Key = @import("Key.zig");
const routing_tests = @import("routing_tests.zig");
const Capture = @This();

actions: [8]routing_tests.Action = undefined,
action_count: usize = 0,
keys: [8]Key = undefined,
key_count: usize = 0,

pub fn action(self: *Capture, value: routing_tests.Action) !Control {
    self.actions[self.action_count] = value;
    self.action_count += 1;
    return .continue_routing;
}

pub fn key(self: *Capture, value: Key) !void {
    self.keys[self.key_count] = value;
    self.key_count += 1;
}

const GenericRouter = @import("GenericRouter.zig").Type;
const Router = GenericRouter(routing_tests.Action, routing_tests.limits);

pub fn apply(self: *Capture, decision: Router.Decision) !Control {
    switch (decision) {
        .forward => |value| try self.key(value),
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
