const PaneClipboard = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
bytes: []const u8,
