const id = @import("../id.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const PaneResize = @This();

pane_id: id.PaneId,
size: TerminalSizeType,
