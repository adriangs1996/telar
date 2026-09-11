const PaneDescriptor = @This();
const id = @import("id.zig");
const source_namespace = @import("types.zig");
pane_id: id.PaneId,
lifecycle: source_namespace.PaneLifecycle,
