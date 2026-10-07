//! Client-local status clocks shared by native cards and pane headers.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const SnapshotMark = @import("SnapshotMark.zig");
const StatusAge = @import("StatusAge.zig");
const AgentAges = @This();

// SAFETY: observe initializes the replacement entries and copies them into this prefix before returning; readers are bounded by len.
entries: [core.max_agent_snapshot_entries]StatusAge = undefined,
len: u8 = 0,
mark: SnapshotMark = .{},
now_ns: u64 = 0,

/// Reconciles clocks only on snapshot changes; ordinary paints advance one
/// monotonic timestamp. Storage is bounded and never borrows the model.
/// Example: `ages.observe(projection.agents, now_ns);`
pub fn observe(self: *AgentAges, snapshot: *const data.AgentSnapshot, now_ns: u64) void {
    self.now_ns = @max(self.now_ns, now_ns);
    const mark = SnapshotMark.of(snapshot);
    if (self.mark.eql(mark)) {
        return;
    }

    var replacement: [core.max_agent_snapshot_entries]StatusAge = undefined;
    for (snapshot.slice(), 0..) |*agent, index| {
        replacement[index] = if (self.mark.source == mark.source)
            if (self.find(agent.key)) |previous| previous.* else .init(agent, self.now_ns)
        else
            .init(agent, self.now_ns);
        replacement[index].observe(agent, self.now_ns);
    }

    self.len = snapshot.count;
    @memcpy(self.entries[0..self.len], replacement[0..self.len]);
    self.mark = mark;
}

/// Reads the same elapsed age for every occurrence of an agent in a frame.
/// Example: `const seconds = ages.seconds(agent);`
pub fn seconds(self: *const AgentAges, agent: *const data.Agent) u32 {
    const age = self.find(agent.key) orelse return agent.statusAgeSeconds();
    return age.seconds(self.now_ns);
}

/// Uses snapshot order for constant-time reads while painting the agent list.
/// Example: `const seconds = ages.secondsAt(index);`
pub fn secondsAt(self: *const AgentAges, index: usize) u32 {
    return self.entries[0..self.len][index].seconds(self.now_ns);
}

fn find(self: *const AgentAges, key: data.AgentKey) ?*const StatusAge {
    for (self.entries[0..self.len]) |*age| {
        if (std.meta.eql(age.key, key)) {
            return age;
        }
    }

    return null;
}
