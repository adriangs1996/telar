const pane_kind = @import("pane_kind.zig");
const id = @import("id.zig");
const types = @import("types.zig");
const PaneDescriptor = @This();

pane_id: id.PaneId,
lifecycle: types.PaneLifecycle,

kind: pane_kind.PaneKind = .terminal,
pane_generation: u64 = 0,
