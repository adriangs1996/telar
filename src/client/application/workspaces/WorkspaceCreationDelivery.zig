const WorkspaceCreationDelivery = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
deliver: *const fn (*anyopaque, *const client_model.WorkspaceReplacement) anyerror!void,
