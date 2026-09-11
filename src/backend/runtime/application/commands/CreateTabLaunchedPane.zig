/// Stable identity returned after the runtime commits the root pane.
const LaunchedPane = @This();
const source_namespace = @import("create_tab.zig");
id: source_namespace.schema.PaneId,
