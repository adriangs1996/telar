const WorkspaceReconciliationType = @import("../../model/WorkspaceReconciliation.zig");
const Effects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, *const WorkspaceReconciliationType) anyerror!void,
