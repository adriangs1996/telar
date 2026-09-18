const PaneIdType = @import("telar-core").PaneId;
/// Stable identity returned after the runtime commits the root pane.
const LaunchedPane = @This();

id: PaneIdType,

kind: @import("telar-core").PaneKind = .terminal,
pane_generation: u64 = 0,
