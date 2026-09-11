const PaneType = @import("../../../../pane/Pane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const Work = @This();

pane: *PaneType,
current_size: TerminalSizeType,
