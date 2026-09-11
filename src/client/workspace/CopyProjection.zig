const CopyProjection = @This();
const source_namespace = @import("multiplexer.zig");
const input = @import("../input/root.zig");
pane_id: source_namespace.schema.PaneId,
view: input.copy_mode.View,
