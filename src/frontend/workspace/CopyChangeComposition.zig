const CopyChangeComposition = @This();
const source_namespace = @import("multiplexer.zig");
const layout_mod = @import("telar-client").workspace.layout;
const RenderStats = @import("RenderStats.zig");
pane: *const source_namespace.Pane,
view: layout_mod.View,
rows: u16,
cols: u16,
stats: *RenderStats,
