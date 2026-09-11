const id = @import("../id.zig");
const SearchMatchType = @import("../SearchMatch.zig");
/// Reply to `search_pane`: every match in document order, at most
/// `max_search_matches`. `truncated` reports that older rows or later
/// matches were not examined.
const PaneMatches = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
truncated: bool,
matches: []const SearchMatchType,
