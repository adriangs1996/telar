const Bookmark = @This();
const source_namespace = @import("navigation.zig");
const layout_mod = @import("layout_support.zig");
location: source_namespace.schema.TabLocation,
pane_id: source_namespace.schema.PaneId,
tab_layout: ?layout_mod.Layout = null,
