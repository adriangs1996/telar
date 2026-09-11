const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const SidebarEffects = @This();

context: *anyopaque,
apply: *const fn (*anyopaque, SidebarLayoutType) anyerror!void,
