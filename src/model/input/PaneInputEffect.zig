const core = @import("telar-core");
const PaneInputEffect = @This();

pane_id: core.PaneId,
/// Borrowed only for the synchronous send effect.
bytes: []const u8,
