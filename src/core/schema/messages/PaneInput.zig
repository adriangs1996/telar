const id = @import("../id.zig");
const PaneInput = @This();

pane_id: id.PaneId,
bytes: []const u8,
