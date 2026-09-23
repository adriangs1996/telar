const core = @import("telar-core");
const Pane = @import("../../pane/Pane.zig");
const Work = @This();

pane: *Pane,
current_size: core.TerminalSize,
