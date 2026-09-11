const WorkspaceOperationGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
