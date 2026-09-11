const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentStatusChange = @import("AgentStatusChange.zig");
const std = @import("std");
const AgentStatusChanges = @This();

items: [max_agent_snapshot_entries]AgentStatusChange = undefined,
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
