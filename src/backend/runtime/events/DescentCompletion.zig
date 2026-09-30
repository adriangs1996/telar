const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Session = @import("../client/Session.zig");
/// Whether the process at the other end of one client connection descends
/// from the pane generation it named, as an observation worker found by
/// walking that process's parents.
const DescentCompletion = @This();

client: ClientKey,
request_id: core.RequestId,
pane: PaneKey,
descends: bool,
/// The peer's parent processes, nearest first.
ancestors: [Session.max_hook_lineage]u32 = undefined,
ancestor_count: u8 = 0,

/// The walked parents.
///
/// ```zig
/// for (completion.lineage()) |pid| {}
/// ```
pub fn lineage(self: *const DescentCompletion) []const u32 {
    return self.ancestors[0..self.ancestor_count];
}
