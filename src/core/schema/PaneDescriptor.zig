const id = @import("id.zig");
const types = @import("types.zig");
const PaneDescriptor = @This();

pane_id: id.PaneId,
lifecycle: types.PaneLifecycle,
