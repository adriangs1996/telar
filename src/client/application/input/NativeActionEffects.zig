const Effects = @This();
const source_namespace = @import("native_action.zig");
context: *anyopaque,
leave_copy_mode: *const fn (*anyopaque) anyerror!void,
deliver: *const fn (*anyopaque, source_namespace.Action) anyerror!source_namespace.Control,
