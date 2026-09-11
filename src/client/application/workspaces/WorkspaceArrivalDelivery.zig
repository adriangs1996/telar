const WorkspaceArrivalDelivery = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
deliver: *const fn (*anyopaque, client_model.WorkspaceActivation) anyerror!void,
