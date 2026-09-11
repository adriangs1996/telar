const RequestSnapshot = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
/// Last frame applied by the client. Zero means it has no pane state.
known_frame_id: u64,
