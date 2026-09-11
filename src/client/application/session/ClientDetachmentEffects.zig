const Effects = @This();
const source_namespace = @import("client_detachment.zig");
context: *anyopaque,
detach_tab: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
