const TabOperationGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
