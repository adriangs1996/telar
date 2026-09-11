const RequestCapacity = @This();

context: *anyopaque,
ensure: *const fn (*anyopaque, u64) anyerror!void,
