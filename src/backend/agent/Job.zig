const Job = @This();
const pane_mod = @import("../pane/root.zig");
const source_namespace = @import("description.zig");
pane: pane_mod.PaneKey,
session_id: [16]u8,
provider: source_namespace.schema.AgentProvider,
query: [source_namespace.max_query_bytes]u8 = undefined,
query_len: u16,

pub fn querySlice(job: *const Job) []const u8 {
    return job.query[0..job.query_len];
}
