const Bookmark = @This();
const source_namespace = @import("workspace_arrival_planning.zig");
location: source_namespace.schema.TabLocation,
tab_layout: ?source_namespace.layout_mod.Layout,
