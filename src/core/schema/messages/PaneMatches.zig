/// Reply to `search_pane`: every match in document order, at most
/// `max_search_matches`. `truncated` reports that older rows or later
/// matches were not examined.
const PaneMatches = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
truncated: bool,
matches: []const source_namespace.SearchMatch,
