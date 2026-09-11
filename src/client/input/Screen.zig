const Screen = @This();
const source_namespace = @import("copy_mode.zig");
buffer: *const source_namespace.ui.Buffer,
scroll: source_namespace.schema.frame.Scroll,
