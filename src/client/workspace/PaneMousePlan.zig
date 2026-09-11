const PaneMousePlan = @This();
const source_namespace = @import("multiplexer.zig");
pane_id: source_namespace.schema.PaneId,
content: source_namespace.ui.Rect,
protocol: source_namespace.schema.frame.Mouse,
alternate_scroll: bool,
at_bottom: bool,
