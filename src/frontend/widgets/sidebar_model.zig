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
    workspace_label: []const u8 = "",
    tab_label: []const u8 = "",
    session_title: []const u8 = "",
    title_source: schema.AgentTitleSource = .telar,
    title_state: schema.AgentTitleState = .placeholder,
    cwd_label: []const u8 = "",
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
};

pub const Agent = struct {
    key: AgentKey,
    location: schema.TabLocation,
    pane_index: u16,
    workspace_label: [schema.max_agent_workspace_label_bytes]u8 = undefined,
    workspace_label_len: u8 = 0,
    tab_label: [schema.max_tab_label_bytes]u8 = undefined,
    tab_label_len: u8 = 0,
    session_title: [schema.max_agent_session_title_bytes]u8 = undefined,
    session_title_len: u8 = 0,
    title_source: schema.AgentTitleSource,
    title_state: schema.AgentTitleState,
    cwd_label: [schema.max_agent_cwd_label_bytes]u8 = undefined,
    cwd_label_len: u8 = 0,
    provider: schema.AgentProvider,
    status: schema.AgentStatus,

    fn init(input: AgentInput) !Agent {
        var agent: Agent = .{
            .key = input.key,
            .location = input.location,
            .pane_index = input.pane_index,
            .title_source = input.title_source,
            .title_state = input.title_state,
            .provider = input.provider,
            .status = input.status,
        };
        agent.workspace_label_len = try copyLabel(
            &agent.workspace_label,
            input.workspace_label,
        );
        agent.tab_label_len = try copyLabel(&agent.tab_label, input.tab_label);
        agent.session_title_len = try copyLabel(&agent.session_title, input.session_title);
        agent.cwd_label_len = try copyLabel(&agent.cwd_label, input.cwd_label);
        return agent;
    }

    pub fn workspaceLabel(agent: *const Agent) []const u8 {
        return agent.workspace_label[0..agent.workspace_label_len];
    }

    pub fn tabLabel(agent: *const Agent) []const u8 {
        return agent.tab_label[0..agent.tab_label_len];
    }

    pub fn sessionTitle(agent: *const Agent) []const u8 {
        return agent.session_title[0..agent.session_title_len];
    }

    pub fn cwdLabel(agent: *const Agent) []const u8 {
        return agent.cwd_label[0..agent.cwd_label_len];
    }
};

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
            replacement.items[index] = try .init(agent);
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

fn copyLabel(destination: []u8, source: []const u8) !u8 {
    if (source.len > destination.len) return error.SidebarLabelTooLong;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidSidebarLabel;
    for (source) |byte| if (byte < 0x20 or byte == 0x7f)
        return error.InvalidSidebarLabel;
    @memcpy(destination[0..source.len], source);
    return @intCast(source.len);
}

test "snapshots own current agents and ignore stale replacement" {
    var snapshot: Snapshot = .{};
    const agents = [_]AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .workspace_label = "telar",
        .tab_label = "main",
        .session_title = "Improve sidebar",
        .title_source = .generated,
        .title_state = .ready,
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .status = .working,
    }};
    try std.testing.expect(try snapshot.replace(.{ .revision = 4, .agents = &agents }));
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot.slice()[0].provider);
    try std.testing.expectEqualStrings("Improve sidebar", snapshot.slice()[0].sessionTitle());
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .agents = &.{} }));
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "snapshot owns every display label" {
    var snapshot: Snapshot = .{};
    var title = [_]u8{ 'f', 'i', 'r', 's', 't' };
    const input: AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .workspace_label = "telar",
        .tab_label = "main",
        .session_title = &title,
        .cwd_label = "~/sandbox/telar",
        .provider = .codex,
        .status = .ready,
    };
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{input} });
    title[0] = 'x';
    try std.testing.expectEqualStrings("first", snapshot.slice()[0].sessionTitle());
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
