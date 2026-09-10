//! Client-side agent identities and the bounded runtime snapshot replica.

pub const snapshot = @import("snapshot.zig");

pub const max_agents = snapshot.max_agents;
pub const Agent = snapshot.Agent;
pub const AgentInput = snapshot.AgentInput;
pub const AgentKey = snapshot.AgentKey;
pub const Snapshot = snapshot.Snapshot;
pub const SnapshotInput = snapshot.SnapshotInput;

test {
    _ = snapshot;
}
