const core = @import("telar-core");
const PaneInputSource = @import("PaneInputSource.zig").PaneInputSource;

pane_id: core.PaneId,
byte_count: usize,
source: PaneInputSource,
