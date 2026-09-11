const PaneInputEffect = @This();
const source_namespace = @import("pane_input.zig");
pane_id: source_namespace.schema.PaneId,
/// Borrowed only for the synchronous send effect.
bytes: []const u8,
