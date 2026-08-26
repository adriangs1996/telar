//! Bounded client replica of the runtime's currently open agents.
//!
//! The runtime owns agent truth. This model only copies the latest snapshot so
//! the sidebar can render it without allocations or access to live pane state.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_agents = schema.max_agent_snapshot_entries;

pub const AgentKey = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,
};

pub const AgentInput = struct {
    key: AgentKey,
    location: schema.TabLocation,
    pane_index: u16,
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
};

pub const Agent = AgentInput;

pub const SnapshotInput = struct {
    revision: u64,
    agents: []const AgentInput,
};

pub const Snapshot = struct {
    revision: u64 = 0,
    initialized: bool = false,
    items: [max_agents]Agent = undefined,
    count: u8 = 0,

    pub fn replace(snapshot: *Snapshot, input: SnapshotInput) !bool {
        if (snapshot.initialized and input.revision <= snapshot.revision) return false;
        if (input.agents.len > max_agents) return error.TooManySidebarAgents;

        var replacement: Snapshot = .{
            .revision = input.revision,
            .initialized = true,
            .count = @intCast(input.agents.len),
        };
        for (input.agents, 0..) |agent, index| {
            for (input.agents[0..index]) |previous| {
                if (std.meta.eql(previous.key, agent.key))
                    return error.DuplicateSidebarAgent;
            }
            replacement.items[index] = agent;
        }
        snapshot.* = replacement;
        return true;
    }

    pub fn slice(snapshot: *const Snapshot) []const Agent {
        return snapshot.items[0..snapshot.count];
    }

    pub fn find(snapshot: *const Snapshot, key: AgentKey) ?*const Agent {
        for (snapshot.slice()) |*agent| {
            if (std.meta.eql(agent.key, key)) return agent;
        }
        return null;
    }

    pub fn setPaneIndex(snapshot: *Snapshot, pane_id: schema.PaneId, pane_index: u16) void {
        for (snapshot.items[0..snapshot.count]) |*agent| {
            if (agent.key.pane_id == pane_id) agent.pane_index = pane_index;
        }
    }

    pub fn keyForPane(
        snapshot: *const Snapshot,
        location: schema.TabLocation,
        pane_id: schema.PaneId,
    ) ?AgentKey {
        for (snapshot.slice()) |agent| {
            if (agent.key.pane_id == pane_id and std.meta.eql(agent.location, location))
                return agent.key;
        }
        return null;
    }

    pub fn hasWorkingAgent(snapshot: *const Snapshot) bool {
        for (snapshot.slice()) |agent| if (agent.status == .working) return true;
        return false;
    }
};

test "snapshots own current agents and ignore stale replacement" {
    var snapshot: Snapshot = .{};
    const agents = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }};
    try std.testing.expect(try snapshot.replace(.{ .revision = 4, .agents = &agents }));
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot.slice()[0].provider);
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .agents = &.{} }));
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "duplicate agent generations are rejected" {
    var snapshot: Snapshot = .{};
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    };
    try std.testing.expectError(
        error.DuplicateSidebarAgent,
        snapshot.replace(.{ .revision = 1, .agents = &.{ agent, agent } }),
    );
}

test "pane projection is scoped to its tab" {
    var snapshot: Snapshot = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const agent: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = location,
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectEqualDeep(
        agent.key,
        snapshot.keyForPane(location, agent.key.pane_id).?,
    );
    try std.testing.expect(snapshot.keyForPane(.{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(3),
    }, agent.key.pane_id) == null);
    try std.testing.expect(snapshot.keyForPane(location, @enumFromInt(8)) == null);
}
