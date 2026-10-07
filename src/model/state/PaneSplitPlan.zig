const core = @import("telar-core");
const PaneSplit = @import("PaneSplit.zig");

split: PaneSplit,
provisional_resize: core.PaneResize,
restore_resize: core.PaneResize,
new_pane_size: core.TerminalSize,
arguments: []const []const u8 = &.{},
