const HandoffGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
