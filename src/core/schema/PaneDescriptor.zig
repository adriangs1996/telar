const id = @import("id.zig");
const types = @import("types.zig");
const PaneDescriptor = @This();

pane_id: id.PaneId,
lifecycle: types.PaneLifecycle,

kind: @import("pane_kind.zig").PaneKind = .terminal,
pane_generation: u64 = 0,
