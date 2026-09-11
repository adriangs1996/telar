const Screen = @This();
const source_namespace = @import("path_marker.zig");
buffer: *const source_namespace.ui.Buffer,
cursor: source_namespace.schema.frame.Cursor,
