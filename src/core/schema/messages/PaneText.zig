/// Reply to `read_pane`. `truncated` reports that older rows were omitted to
/// respect `max_pane_text_bytes`.
const PaneText = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
truncated: bool,
text: []const u8,
