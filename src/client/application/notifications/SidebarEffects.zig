const SidebarEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
apply: *const fn (*anyopaque, client_model.SidebarLayout) anyerror!void,
