const action = @import("../../input/action.zig");
const action_routing = @import("action_routing.zig");
const Effects = @This();

context: *anyopaque,
leave_copy_mode: *const fn (*anyopaque) anyerror!void,
deliver: *const fn (*anyopaque, action.Action) anyerror!action_routing.Control,
