const PaneSplitPlan = @This();
const PaneSplit = @import("PaneSplit.zig");
const source_namespace = @import("types.zig");
split: PaneSplit,
provisional_resize: source_namespace.PaneResize,
restore_resize: source_namespace.PaneResize,
new_pane_size: source_namespace.schema.TerminalSize,
