const Capture = @This();
const source_namespace = @import("request_router.zig");
calls: usize = 0,
last: ?source_namespace.Tag = null,
failure: ?source_namespace.Tag = null,
pane_input: ?source_namespace.schema.PaneInput = null,
