const WorkspaceCreationGate = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
