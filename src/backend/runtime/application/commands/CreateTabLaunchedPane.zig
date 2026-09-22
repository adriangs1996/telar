const core = @import("telar-core");
/// Stable identity returned after the runtime commits the root pane.
const LaunchedPane = @This();

id: core.PaneId,

kind: core.PaneKind = .terminal,
pane_generation: u64 = 0,
