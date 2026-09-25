const core = @import("telar-core");
const PaneInputSource = @import("PaneInputSource.zig").PaneInputSource;
const PaneInputDelivery = @This();

pane_id: core.PaneId,
byte_count: usize,
source: PaneInputSource,
