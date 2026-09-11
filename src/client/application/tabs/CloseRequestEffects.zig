const CloseRequestEffects = @This();
const source_namespace = @import("close_tab.zig");
const TabCloseIntent = @import("TabCloseIntent.zig");
context: *anyopaque,
detach: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
send: *const fn (*anyopaque, TabCloseIntent) anyerror!void,
