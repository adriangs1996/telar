const PaneIdType = @import("telar-core").PaneId;
const pane_input = @import("pane_input.zig");
const Delivery = @This();

pane_id: PaneIdType,
byte_count: usize,
source: pane_input.Source,
