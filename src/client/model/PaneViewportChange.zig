const PaneViewportChange = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
offset: u32,
at_bottom: bool,
viewport_revision: u64,
