const ActivationEffects = @This();
const TimerEffects = @import("TimerEffects.zig");
const notification_capability = @import("../../root.zig").notifications;
timers: TimerEffects,
context: *anyopaque,
navigate: *const fn (*anyopaque, notification_capability.Target) anyerror!void,
