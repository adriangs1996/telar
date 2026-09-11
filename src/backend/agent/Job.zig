const PaneKeyType = @import("../pane/PaneKey.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const description = @import("description.zig");
const Job = @This();

pane: PaneKeyType,
session_id: [16]u8,
provider: AgentProviderType,
query: [description.max_query_bytes]u8 = undefined,
query_len: u16,

pub fn querySlice(job: *const Job) []const u8 {
    return job.query[0..job.query_len];
}
