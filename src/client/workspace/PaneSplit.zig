const core = @import("telar-core");
const model_data = @import("model");
const PaneSplit = @This();

existing_pane: core.PaneId,
new_pane: core.PaneId,
location: core.TabLocation,
axis: model_data.LayoutAxis,
area: core.Rect,
