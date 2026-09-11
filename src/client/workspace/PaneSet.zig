const PaneSet = @This();
const source_namespace = @import("layout_support.zig");
ids: []const source_namespace.schema.PaneId,
focused: source_namespace.schema.PaneId,
