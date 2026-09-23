const PaneKey = @import("../../pane/PaneKey.zig");
const PaneIngestStats = @import("../../pane/PaneIngestStats.zig");
const Completion = @This();

pane: PaneKey,
result: anyerror!PaneIngestStats,
