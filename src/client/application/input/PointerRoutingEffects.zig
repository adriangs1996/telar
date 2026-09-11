const Effects = @This();
const source_namespace = @import("pointer_routing.zig");
const ViewOutcome = @import("ViewOutcome.zig");
context: *anyopaque,
copy_mode: *const fn (*anyopaque, source_namespace.PointerCommand) anyerror!bool,
view: *const fn (*anyopaque, source_namespace.PointerCommand) anyerror!ViewOutcome,
link: *const fn (*anyopaque, source_namespace.PointerCommand) anyerror!bool,
pane: *const fn (*anyopaque, source_namespace.PointerCommand) anyerror!void,
