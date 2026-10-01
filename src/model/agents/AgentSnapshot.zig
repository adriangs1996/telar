const core = @import("telar-core");
const data = @import("../model.zig");
const Agent = @import("Agent.zig");
const SnapshotInput = @import("SnapshotInput.zig");
const std = @import("std");
const Snapshot = @This();

revision: u64 = 0,
items: [core.max_agent_snapshot_entries]Agent = undefined,
count: u8 = 0,

/// Atomically owns one newer runtime snapshot. Stale revisions and a
/// rejected replacement preserve the previous replica.
///
/// ```zig
/// _ = try snapshot.replace(.{ .revision = 1, .agents = entries });
/// ```
pub fn replace(self: *Snapshot, input: SnapshotInput) !bool {
    if (input.revision <= self.revision) {
        return false;
    }
    if (input.agents.len > core.max_agent_snapshot_entries) {
        return error.TooManyAgents;
    }

    // Validate every entry before writing any, so a rejected replacement
    // keeps the previous replica without a second snapshot on the stack.
    for (input.agents, 0..) |agent, index| {
        for (input.agents[0..index]) |previous| {
            if (std.meta.eql(previous.key, agent.key)) {
                return error.DuplicateAgent;
            }
        }

        _ = try Agent.init(agent);
    }

    for (input.agents, 0..) |agent, index| {
        self.items[index] = Agent.init(agent) catch unreachable;
    }

    self.revision = input.revision;
    self.count = @intCast(input.agents.len);
    return true;
}

/// Borrows all agents in runtime order.
///
/// ```zig
/// for (snapshot.slice()) |agent| inspect(agent);
/// ```
pub fn slice(self: *const Snapshot) []const Agent {
    return self.items[0..self.count];
}

/// Resolves one exact pane generation from the current replica.
///
/// ```zig
/// const agent = snapshot.find(key) orelse return;
/// ```
pub fn find(self: *const Snapshot, key: data.AgentKey) ?*const Agent {
    for (self.slice()) |*agent| {
        if (std.meta.eql(agent.key, key)) {
            return agent;
        }
    }

    return null;
}

/// Resolves the current generation attached to one pane in one tab.
///
/// ```zig
/// const key = snapshot.keyForPane(location, pane_id) orelse return;
/// ```
pub fn keyForPane(self: *const Snapshot, location: core.TabLocation, pane_id: core.PaneId) ?data.AgentKey {
    for (self.slice()) |agent| {
        if (agent.key.pane_id == pane_id and std.meta.eql(agent.location, location)) {
            return agent.key;
        }
    }

    return null;
}

/// Reports whether animation is required by the current runtime state.
///
/// ```zig
/// if (snapshot.hasWorkingAgent()) scheduleTick();
/// ```
pub fn hasWorkingAgent(self: *const Snapshot) bool {
    for (self.slice()) |agent| {
        if (agent.status == .working) {
            return true;
        }
    }

    return false;
}
