const core = @import("telar-core");
const AgentStatusChange = @import("AgentStatusChange.zig");
const std = @import("std");
const AgentStatusChanges = @This();

// SAFETY: append writes a status change before increasing count; slice exposes only that initialized prefix.
items: [core.max_agent_snapshot_entries]AgentStatusChange = undefined,
count: u8 = 0,

pub fn append(self: *AgentStatusChanges, change: AgentStatusChange) void {
    std.debug.assert(self.count < self.items.len);
    self.items[self.count] = change;
    self.count += 1;
}

/// Borrows status transitions detected during one atomic reconciliation.
///
/// ```zig
/// for (commit.status_changes.slice()) |change| alert(change);
/// ```
pub fn slice(self: *const AgentStatusChanges) []const AgentStatusChange {
    return self.items[0..self.count];
}
