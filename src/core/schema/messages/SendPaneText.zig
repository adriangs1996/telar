/// Text delivered to one exact pane generation without a client attachment.
const SendPaneText = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
mode: source_namespace.PaneTextMode,
text: []const u8,
