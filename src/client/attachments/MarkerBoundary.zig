const MarkerBoundary = @This();
const source_namespace = @import("markers.zig");
ordinal: u16,
cursor: source_namespace.schema.frame.Cursor,
deletion: source_namespace.MarkerDeletion,
