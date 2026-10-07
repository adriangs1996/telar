const id = @import("id.zig");
const types = @import("types.zig");

pane_id: id.PaneId,
lifecycle: types.PaneLifecycle,

pane_generation: u64 = 0,
