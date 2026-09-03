//! Bounded client replica of the runtime's currently open agents.
//!
//! The runtime owns agent truth. This capability owns one immutable client
//! copy so application decisions and presentation read the same revision.

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
    provider_name: []const u8 = "",
    display_name: []const u8 = "",
    icon: []const u8 = "",
    attachments: schema.AgentAttachmentMarkers = .none,
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
    provider_name: [schema.max_agent_provider_name_bytes]u8 = undefined,
    provider_name_len: u8 = 0,
    display_name: [schema.max_agent_display_name_bytes]u8 = undefined,
    display_name_len: u8 = 0,
    icon: [schema.max_agent_icon_bytes]u8 = undefined,
    icon_len: u8 = 0,
    attachments: schema.AgentAttachmentMarkers,
    provider: schema.AgentProvider,
    status: schema.AgentStatus,

    /// Manifest name of the provider ("claude"), or "agent" when the runtime
    /// sent none because the provider is unknown.
    ///
    /// ```zig
    /// const name = agent.providerName();
    /// ```
    pub fn providerName(agent: *const Agent) []const u8 {
        if (agent.provider_name_len != 0) {
            return agent.provider_name[0..agent.provider_name_len];
        }

        return "agent";
    }

    /// Human label of the provider ("Claude Code"), or the generic label when
    /// the runtime sent none.
    ///
    /// ```zig
    /// const label = agent.displayName();
    /// ```
    pub fn displayName(agent: *const Agent) []const u8 {
        if (agent.display_name_len != 0) {
            return agent.display_name[0..agent.display_name_len];
        }

        return core.agent_manifest.generic_display_name;
    }

    /// Configured sidebar glyph; empty when the client should use its own
    /// artwork for the provider.
    ///
    /// ```zig
    /// const glyph = agent.iconGlyph();
    /// ```
    pub fn iconGlyph(agent: *const Agent) []const u8 {
        return agent.icon[0..agent.icon_len];
    }

    fn init(input: AgentInput) !Agent {
        var agent: Agent = .{
            .key = input.key,
            .location = input.location,
            .pane_index = input.pane_index,
            .title_source = input.title_source,
            .title_state = input.title_state,
            .provider = input.provider,
            .attachments = input.attachments,
            .status = input.status,
        };
        agent.workspace_label_len = try copyLabel(&agent.workspace_label, input.workspace_label);
        agent.tab_label_len = try copyLabel(&agent.tab_label, input.tab_label);
        agent.session_title_len = try copyLabel(&agent.session_title, input.session_title);
        agent.cwd_label_len = try copyLabel(&agent.cwd_label, input.cwd_label);
        agent.provider_name_len = try copyLabel(&agent.provider_name, input.provider_name);
        agent.display_name_len = try copyLabel(&agent.display_name, input.display_name);
        agent.icon_len = try copyLabel(&agent.icon, input.icon);

        return agent;
    }

    /// Borrows the workspace label owned by this replica entry.
    ///
    /// ```zig
    /// const label = agent.workspaceLabel();
    /// ```
    pub fn workspaceLabel(agent: *const Agent) []const u8 {
        return agent.workspace_label[0..agent.workspace_label_len];
    }

    /// Borrows the tab label owned by this replica entry.
    ///
    /// ```zig
    /// const label = agent.tabLabel();
    /// ```
    pub fn tabLabel(agent: *const Agent) []const u8 {
        return agent.tab_label[0..agent.tab_label_len];
    }

    /// Borrows the session title owned by this replica entry.
    ///
    /// ```zig
    /// const title = agent.sessionTitle();
    /// ```
    pub fn sessionTitle(agent: *const Agent) []const u8 {
        return agent.session_title[0..agent.session_title_len];
    }

    /// Borrows the cwd label owned by this replica entry.
    ///
    /// ```zig
    /// const cwd = agent.cwdLabel();
    /// ```
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
    items: [max_agents]Agent = undefined,
    count: u8 = 0,

    /// Atomically owns one newer runtime snapshot. Stale revisions and a
    /// rejected replacement preserve the previous replica.
    ///
    /// ```zig
    /// _ = try snapshot.replace(.{ .revision = 1, .agents = entries });
    /// ```
    pub fn replace(snapshot: *Snapshot, input: SnapshotInput) !bool {
        if (input.revision <= snapshot.revision) {
            return false;
        }
        if (input.agents.len > max_agents) {
            return error.TooManyAgents;
        }

        var replacement: Snapshot = .{
            .revision = input.revision,
            .count = @intCast(input.agents.len),
        };
        for (input.agents, 0..) |agent, index| {
            for (input.agents[0..index]) |previous| {
                if (std.meta.eql(previous.key, agent.key)) {
                    return error.DuplicateAgent;
                }
            }

            replacement.items[index] = try .init(agent);
        }

        snapshot.* = replacement;
        return true;
    }

    /// Borrows all agents in runtime order.
    ///
    /// ```zig
    /// for (snapshot.slice()) |agent| inspect(agent);
    /// ```
    pub fn slice(snapshot: *const Snapshot) []const Agent {
        return snapshot.items[0..snapshot.count];
    }

    /// Resolves one exact pane generation from the current replica.
    ///
    /// ```zig
    /// const agent = snapshot.find(key) orelse return;
    /// ```
    pub fn find(snapshot: *const Snapshot, key: AgentKey) ?*const Agent {
        for (snapshot.slice()) |*agent| {
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
    pub fn keyForPane(snapshot: *const Snapshot, location: schema.TabLocation, pane_id: schema.PaneId) ?AgentKey {
        for (snapshot.slice()) |agent| {
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
    pub fn hasWorkingAgent(snapshot: *const Snapshot) bool {
        for (snapshot.slice()) |agent| {
            if (agent.status == .working) {
                return true;
            }
        }

        return false;
    }
};

fn copyLabel(destination: []u8, source: []const u8) !u8 {
    if (source.len > destination.len) {
        return error.AgentLabelTooLong;
    }
    if (!std.unicode.utf8ValidateSlice(source)) {
        return error.InvalidAgentLabel;
    }

    for (source) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidAgentLabel;
        }
    }

    @memcpy(destination[0..source.len], source);
    return @intCast(source.len);
}

fn testingAgent() AgentInput {
    return .{
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
    };
}

test "snapshots own current agents and ignore stale replacement" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();

    try std.testing.expect(try snapshot.replace(.{ .revision = 4, .agents = &.{agent} }));
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot.slice()[0].provider);
    try std.testing.expectEqualStrings("Improve sidebar", snapshot.slice()[0].sessionTitle());
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .agents = &.{} }));
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "snapshot owns every display label" {
    var snapshot: Snapshot = .{};
    var title = [_]u8{ 'f', 'i', 'r', 's', 't' };
    var agent = testingAgent();
    agent.session_title = &title;

    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    title[0] = 'x';

    try std.testing.expectEqualStrings("first", snapshot.slice()[0].sessionTitle());
}

test "rejected replacement preserves the complete previous snapshot" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    var invalid = agent;
    invalid.session_title = "broken\nlabel";

    try std.testing.expectError(error.InvalidAgentLabel, snapshot.replace(.{
        .revision = 2,
        .agents = &.{invalid},
    }));

    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqualDeep(agent.key, snapshot.slice()[0].key);
    try std.testing.expectEqualStrings(agent.session_title, snapshot.slice()[0].sessionTitle());
}

test "duplicate agent generations are rejected" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();

    try std.testing.expectError(error.DuplicateAgent, snapshot.replace(.{
        .revision = 1,
        .agents = &.{ agent, agent },
    }));
}

test "pane lookup is scoped to its tab and exact generation" {
    var snapshot: Snapshot = .{};
    const agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectEqualDeep(agent.key, snapshot.keyForPane(agent.location, agent.key.pane_id).?);
    try std.testing.expect(snapshot.keyForPane(.{
        .workspace = agent.location.workspace,
        .tab_id = @enumFromInt(3),
    }, agent.key.pane_id) == null);
    try std.testing.expect(snapshot.find(.{
        .pane_id = agent.key.pane_id,
        .pane_generation = agent.key.pane_generation + 1,
    }) == null);
}

test "working state is queried without mutating the replica" {
    var snapshot: Snapshot = .{};
    var agent = testingAgent();
    _ = try snapshot.replace(.{ .revision = 1, .agents = &.{agent} });
    const revision = snapshot.revision;

    try std.testing.expect(snapshot.hasWorkingAgent());
    try std.testing.expectEqual(revision, snapshot.revision);

    agent.status = .ready;
    _ = try snapshot.replace(.{ .revision = 2, .agents = &.{agent} });
    try std.testing.expect(!snapshot.hasWorkingAgent());
}
