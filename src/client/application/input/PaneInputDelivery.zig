const core = @import("telar-core");
const pane_input = @import("pane_input.zig");
const Delivery = @This();

pane_id: core.PaneId,
byte_count: usize,
source: pane_input.Source,
