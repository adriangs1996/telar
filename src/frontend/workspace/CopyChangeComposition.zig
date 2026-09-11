const PaneType = @import("telar-client").Pane;
const ViewType = @import("telar-client").LayoutView;
const RenderStats = @import("RenderStats.zig");
const CopyChangeComposition = @This();

pane: *const PaneType,
view: ViewType,
rows: u16,
cols: u16,
stats: *RenderStats,
