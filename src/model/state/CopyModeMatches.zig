const core = @import("telar-core");

pane_id: core.PaneId,
/// Borrowed only for the synchronous transition.
matches: []const core.SearchMatch,
