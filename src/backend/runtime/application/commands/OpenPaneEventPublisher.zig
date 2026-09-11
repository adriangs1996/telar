const open_pane = @import("open_pane.zig");
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, open_pane.RuntimeEvent) void,
