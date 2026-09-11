const PaneIdType = @import("telar-core").PaneId;
const PaneInputEffect = @This();

pane_id: PaneIdType,
/// Borrowed only for the synchronous send effect.
bytes: []const u8,
