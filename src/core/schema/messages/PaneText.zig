const id = @import("../id.zig");
/// Reply to `read_pane`. `truncated` reports that older rows were omitted to
/// respect `max_pane_text_bytes`.
const PaneText = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
truncated: bool,
text: []const u8,
