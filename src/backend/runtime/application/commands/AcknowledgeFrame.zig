const AcknowledgeFrame = @This();
const source_namespace = @import("frame_ack.zig");
pane_id: source_namespace.schema.PaneId,
frame_id: u64,
received_at_ns: u64,
