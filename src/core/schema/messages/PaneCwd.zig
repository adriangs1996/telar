const id = @import("../id.zig");
const PaneCwd = @This();

pane_id: id.PaneId,
cwd: []const u8,
