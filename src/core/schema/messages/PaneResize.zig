const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const PaneResize = @This();

pane_id: id.PaneId,
size: TerminalSize,
