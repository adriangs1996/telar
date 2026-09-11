/// Owned title projection emitted only after the agent aggregate accepts and
/// validates a description result.
const DescriptionFinished = @This();
const source_namespace = @import("types.zig");
pane: source_namespace.PaneKey,
session_id: [16]u8,
title: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
source: source_namespace.schema.AgentTitleSource,
state: source_namespace.schema.AgentTitleState,

/// Returns the title bytes owned by this completion event.
///
/// ```zig
/// try persist(finished.titleSlice());
/// ```
pub fn titleSlice(finished: *const DescriptionFinished) []const u8 {
    return finished.title[0..finished.title_len];
}
