const core = @import("telar-core");
const PaneKeyType = @import("../pane/PaneKey.zig");
/// Owned title projection emitted only after the agent aggregate accepts and
/// validates a description result.
const DescriptionFinished = @This();

pane: PaneKeyType,
session_id: [16]u8,
title: [core.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
source: core.AgentTitleSource,
state: core.AgentTitleState,

/// Returns the title bytes owned by this completion event.
///
/// ```zig
/// try persist(finished.titleSlice());
/// ```
pub fn titleSlice(finished: *const DescriptionFinished) []const u8 {
    return finished.title[0..finished.title_len];
}
