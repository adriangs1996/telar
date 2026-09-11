const RequestIdType = @import("telar-core").RequestId;
const PaneIdType = @import("telar-core").PaneId;
const MatchesType = @import("../application/commands/Matches.zig");
/// Search matches are small and computed at request time, so the reply owns
/// its copy.
const PendingPaneMatches = @This();

request_id: RequestIdType,
pane_id: PaneIdType,
matches: MatchesType,
