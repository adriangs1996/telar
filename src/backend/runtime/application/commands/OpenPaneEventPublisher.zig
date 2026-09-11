const EventPublisher = @This();
const source_namespace = @import("open_pane.zig");
context: *anyopaque,
publish: *const fn (*anyopaque, source_namespace.RuntimeEvent) void,
