const Completion = @This();
const source_namespace = @import("root.zig");
detach_pane: ?source_namespace.schema.PaneId = null,
close_client: bool = false,
stopping_delivered: bool = false,
