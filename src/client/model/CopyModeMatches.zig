const CopyModeMatches = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
/// Borrowed only for the synchronous transition.
matches: []const source_namespace.schema.SearchMatch,
