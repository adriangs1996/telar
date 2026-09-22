const core = @import("telar-core");
const MatchesType = @import("../application/commands/Matches.zig");
/// Search matches are small and computed at request time, so the reply owns
/// its copy.
const PendingPaneMatches = @This();

request_id: core.RequestId,
pane_id: core.PaneId,
matches: MatchesType,
