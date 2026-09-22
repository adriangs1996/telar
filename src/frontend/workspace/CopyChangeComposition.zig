const client = @import("telar-client");
const data = @import("model");
const RenderStats = @import("RenderStats.zig");
const CopyChangeComposition = @This();

pane: *const data.Pane,
view: data.LayoutView,
rows: u16,
cols: u16,
stats: *RenderStats,
