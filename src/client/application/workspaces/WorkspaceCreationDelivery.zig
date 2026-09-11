const WorkspaceReplacementType = @import("../../model/WorkspaceReplacement.zig");
const WorkspaceCreationDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, *const WorkspaceReplacementType) anyerror!void,
