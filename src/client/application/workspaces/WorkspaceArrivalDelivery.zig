const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");
const WorkspaceArrivalDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, WorkspaceActivationType) anyerror!void,
