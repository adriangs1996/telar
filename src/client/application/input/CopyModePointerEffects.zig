const PointerMotionType = @import("../../input/PointerMotion.zig");
const Effects = @This();

context: *anyopaque,
leave: *const fn (*anyopaque) anyerror!void,
vertical: *const fn (*anyopaque, i32) anyerror!void,
pointer: *const fn (*anyopaque, PointerMotionType) anyerror!void,
cancel_pointer: *const fn (*anyopaque) anyerror!void,
