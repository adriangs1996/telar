const PaneSplit = @import("PaneSplit.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const TerminalSizeType = @import("telar-core").TerminalSize;
const PaneSplitPlan = @This();

split: PaneSplit,
provisional_resize: PaneResizeType,
restore_resize: PaneResizeType,
new_pane_size: TerminalSizeType,
