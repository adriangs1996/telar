const types = @import("../../model/types.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const close_tab = @import("close_tab.zig");
const RemovalDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, types.TabRemovalCommit, ?WorkspaceIdType) anyerror!close_tab.TabRemovalDirective,
