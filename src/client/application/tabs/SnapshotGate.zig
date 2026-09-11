const SnapshotGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
