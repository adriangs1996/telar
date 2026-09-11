const PaneType = @import("../../../../pane/Pane.zig");
const StatsType = @import("../../../../history/Stats.zig");
const ScreenReconciliation = @This();

pane: *PaneType,
stats: StatsType,
shell_foreground: bool,
