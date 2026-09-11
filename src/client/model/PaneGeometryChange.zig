const PaneGeometryChange = @This();
const source_namespace = @import("types.zig");
location: source_namespace.schema.TabLocation,
focused: source_namespace.schema.PaneId,
panes_revision: u64,
area: source_namespace.ui.Rect,
fullscreen: bool,
