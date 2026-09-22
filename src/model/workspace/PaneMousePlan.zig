const core = @import("telar-core");
const PaneMousePlan = @This();

pane_id: core.PaneId,
content: core.Rect,
protocol: core.Mouse,
alternate_scroll: bool,
at_bottom: bool,
