const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const MouseType = @import("telar-core").Mouse;
const PaneMousePlan = @This();

pane_id: PaneIdType,
content: RectType,
protocol: MouseType,
alternate_scroll: bool,
at_bottom: bool,
