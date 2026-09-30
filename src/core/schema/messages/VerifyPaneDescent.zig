const id = @import("../id.zig");
const types = @import("../types.zig");
/// Asks whether the process that sends it descends from one exact pane
/// generation: whether its chain of parent processes, nearest first, reaches
/// the pane's root process. A hook asks before it reports, because the pane
/// identity in its environment may belong to a process that left the pane,
/// such as a shared server started there.
const VerifyPaneDescent = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
ancestor_count: u8 = 0,
ancestors: [types.max_pane_descent_ancestors]u32 = @splat(0),

/// The parent processes the sender named, nearest first.
///
/// ```zig
/// for (request.slice()) |pid| {}
/// ```
pub fn slice(self: *const VerifyPaneDescent) []const u32 {
    return self.ancestors[0..self.ancestor_count];
}
