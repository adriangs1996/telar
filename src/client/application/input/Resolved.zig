const Resolved = @This();
const source_namespace = @import("pane_mouse.zig");
const PointerCommand = @import("PointerCommand.zig");
plan: source_namespace.multiplexer.PaneMousePlan,
pointer: PointerCommand,
