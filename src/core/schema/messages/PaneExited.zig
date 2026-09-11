const id = @import("../id.zig");
const types = @import("../types.zig");
const PaneExited = @This();

pane_id: id.PaneId,
kind: types.ExitKind,
value: u32,
