const PaneFocus = @This();
const source_namespace = @import("types.zig");
location: source_namespace.schema.TabLocation,
previous: source_namespace.schema.PaneId,
focused: source_namespace.schema.PaneId,
geometry_changed: bool,
panes_revision: u64,
