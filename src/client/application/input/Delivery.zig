const Delivery = @This();
const source_namespace = @import("pane_input.zig");
pane_id: source_namespace.schema.PaneId,
byte_count: usize,
source: source_namespace.Source,
