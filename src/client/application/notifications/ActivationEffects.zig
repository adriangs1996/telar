const TimerEffects = @import("TimerEffects.zig");
const notification_capability = @import("../../notifications/notifications.zig");
const ActivationEffects = @This();

timers: TimerEffects,
context: *anyopaque,
navigate: *const fn (*anyopaque, notification_capability.Target) anyerror!void,
