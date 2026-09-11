const Gate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
