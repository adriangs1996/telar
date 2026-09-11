const Sink = @This();

context: *anyopaque,
set: *const fn (*anyopaque, []const u8) anyerror!void,
