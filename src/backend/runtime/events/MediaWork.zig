const core = @import("telar-core");
const PaneType = @import("../../pane/Pane.zig");
const Work = @This();

pane: *PaneType,
current_size: core.TerminalSize,
