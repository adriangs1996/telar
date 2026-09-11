const PendingLayoutRestore = @This();
const source_namespace = @import("tabs.zig");
const layout_mod = @import("layout_support.zig");
location: source_namespace.schema.TabLocation,
layout: layout_mod.Layout,
restore_saved_focus: bool = false,
