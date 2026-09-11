const AgentStatusChanges = @This();
const agents = @import("../agents/root.zig");
const AgentStatusChange = @import("AgentStatusChange.zig");
const std = @import("std");
items: [agents.max_agents]AgentStatusChange = undefined,
count: u8 = 0,

pub fn append(changes: *AgentStatusChanges, change: AgentStatusChange) void {
    std.debug.assert(changes.count < changes.items.len);
    changes.items[changes.count] = change;
    changes.count += 1;
}

/// Borrows status transitions detected during one atomic reconciliation.
///
/// ```zig
/// for (commit.status_changes.slice()) |change| alert(change);
/// ```
pub fn slice(changes: *const AgentStatusChanges) []const AgentStatusChange {
    return changes.items[0..changes.count];
}
