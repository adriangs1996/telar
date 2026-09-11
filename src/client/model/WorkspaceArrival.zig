const WorkspaceArrival = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
size: source_namespace.schema.TerminalSize,
saved_layout: ?source_namespace.layout_mod.Layout = null,
