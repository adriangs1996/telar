const TimerEffects = @This();

context: *anyopaque,
reschedule: *const fn (*anyopaque) anyerror!void,
