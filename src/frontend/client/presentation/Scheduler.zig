const Scheduler = @This();

context: *anyopaque,
/// Arms one draw at an absolute deadline; the owner delivers `.draw`.
draw: *const fn (*anyopaque, u64) anyerror!void,
/// Presents synchronously, on the caller's thread, before returning. A
/// frame the pacer lets through does not pay a timer task and a wakeup.
draw_now: *const fn (*anyopaque) anyerror!void,
media: *const fn (*anyopaque, u64) anyerror!void,
