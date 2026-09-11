const Effects = @This();

context: *anyopaque,
schedule: *const fn (*anyopaque) anyerror!void,
