/// Committed position of a tab after a move request.
const TabMoved = @This();
const source_namespace = @import("events.zig");
location: source_namespace.schema.TabLocation,
position: u16,
