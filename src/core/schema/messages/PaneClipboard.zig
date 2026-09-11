const id = @import("../id.zig");
const PaneClipboard = @This();

pane_id: id.PaneId,
bytes: []const u8,
