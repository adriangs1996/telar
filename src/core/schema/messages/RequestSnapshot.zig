const id = @import("../id.zig");
const RequestSnapshot = @This();

pane_id: id.PaneId,
/// Last frame applied by the client. Zero means it has no pane state.
known_frame_id: u64,
