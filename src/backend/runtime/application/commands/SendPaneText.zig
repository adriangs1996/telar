const SendPaneText = @This();
const source_namespace = @import("send_pane_text.zig");
pane: source_namespace.PaneKey,
mode: source_namespace.schema.PaneTextMode,
text: []const u8,
