const PaneGraphicsFallbackCommit = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
visible: bool,
pane_graphics_revision: u64,
