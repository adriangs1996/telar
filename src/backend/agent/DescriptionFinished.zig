const PaneKeyType = @import("../pane/PaneKey.zig");
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
/// Owned title projection emitted only after the agent aggregate accepts and
/// validates a description result.
const DescriptionFinished = @This();

pane: PaneKeyType,
session_id: [16]u8,
title: [max_agent_session_title_bytes_module]u8 = undefined,
title_len: u8 = 0,
source: AgentTitleSourceType,
state: AgentTitleStateType,

/// Returns the title bytes owned by this completion event.
///
/// ```zig
/// try persist(finished.titleSlice());
/// ```
pub fn titleSlice(finished: *const DescriptionFinished) []const u8 {
    return finished.title[0..finished.title_len];
}
