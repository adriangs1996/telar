const Effects = @This();
const copy_mode = @import("../../input/root.zig").copy_mode;
context: *anyopaque,
leave: *const fn (*anyopaque) anyerror!void,
vertical: *const fn (*anyopaque, i32) anyerror!void,
pointer: *const fn (*anyopaque, copy_mode.PointerMotion) anyerror!void,
cancel_pointer: *const fn (*anyopaque) anyerror!void,
