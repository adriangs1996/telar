const FastWrite = @This();

context: *anyopaque,
write: *const fn (*anyopaque, []const u8) anyerror!usize,
