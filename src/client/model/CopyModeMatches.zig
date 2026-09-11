const PaneIdType = @import("telar-core").PaneId;
const SearchMatchType = @import("telar-core").SearchMatch;
const CopyModeMatches = @This();

pane_id: PaneIdType,
/// Borrowed only for the synchronous transition.
matches: []const SearchMatchType,
