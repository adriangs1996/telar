const PaneOperationGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
