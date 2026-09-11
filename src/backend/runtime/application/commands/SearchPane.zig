const SearchPane = @This();
const source_namespace = @import("search_pane.zig");
pane_id: source_namespace.schema.PaneId,
needle: []const u8,
