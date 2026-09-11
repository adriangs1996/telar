const PaneKeyType = @import("../../../../pane/PaneKey.zig");
const PaneIngestStats = @import("../../../../pane/PaneIngestStats.zig");
const Completion = @This();

pane: PaneKeyType,
result: anyerror!PaneIngestStats,
