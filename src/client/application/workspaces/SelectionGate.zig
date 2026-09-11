const SelectionGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
