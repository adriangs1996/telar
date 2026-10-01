//! The fleet order both sidebars draw: agents grouped by project in project
//! list order. Inside a group each agent of the project's own checkout is
//! followed by its tasks, the agents working in worktrees its pane created;
//! the tasks nobody alive created come last, under no one. Each part keeps
//! the shared attention order. A task that needs the person (blocked,
//! failed, finished unseen) or is selected is drawn in full; the rest take
//! one line. See `docs/flows/task-cards.md`.

const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const attention = @import("attention.zig");
const FleetEntry = @import("FleetEntry.zig");
const FleetCard = @import("FleetCard.zig").FleetCard;
const FleetSources = @import("FleetSources.zig");

pub const max_entries = core.max_agent_snapshot_entries;

/// Writes the fleet order into `output` and returns it.
///
/// ```zig
/// var entries: [fleet_order.max_entries]FleetEntry = undefined;
/// const fleet = fleet_order.order(.{ .agents = agents, .workspaces = &snapshot }, &entries);
/// ```
pub fn order(sources: FleetSources, output: *[max_entries]FleetEntry) []const FleetEntry {
    const count = @min(sources.agents.len, max_entries);
    for (output[0..count], 0..) |*entry, index| {
        const agent = &sources.agents[index];
        entry.* = .{
            .index = @intCast(index),
            .card = card(sources, agent),
            .project = projectOf(sources.workspaces, agent),
        };
    }

    for (output[0..count]) |*entry| {
        entry.creator = creatorOf(sources, output[0..count], entry.*);
    }

    std.sort.pdq(FleetEntry, output[0..count], sources, lessThan);
    var previous: ?core.WorkspaceId = null;
    for (output[0..count], 0..) |*entry, position| {
        entry.first_in_project = position == 0 or entry.project != previous;
        previous = entry.project;
    }

    return output[0..count];
}

/// Whether an agent works in a tracked worktree: its reported work tree, or
/// the workspace holding its pane.
///
/// ```zig
/// if (fleet_order.isTask(&snapshot, agent)) drawTaskCard();
/// ```
pub fn isTask(workspaces: *const data.WorkspaceListSnapshot, agent: *const data.Agent) bool {
    return taskRow(workspaces, agent) != null;
}

/// The worktree row of an agent's task, when it has one.
///
/// ```zig
/// const row = fleet_order.taskRow(&snapshot, agent) orelse return;
/// ```
pub fn taskRow(workspaces: *const data.WorkspaceListSnapshot, agent: *const data.Agent) ?*const data.WorktreeRow {
    if (workspaces.worktree(agent.work_tree)) |row| {
        return row;
    }

    const workspace = switch (agent.location.workspace) {
        .workspace => |id| id,
        .worktree => return null,
    };
    return workspaces.worktreeOfWorkspace(workspace);
}

fn card(sources: FleetSources, agent: *const data.Agent) FleetCard {
    if (!isTask(sources.workspaces, agent)) {
        return .agent;
    }

    if (sources.focused == agent.key.pane_id) {
        return .task_full;
    }

    return switch (agent.status) {
        .blocked, .failed, .done => .task_full,
        .working, .ready, .unknown => .task_compact,
    };
}

/// The agent a task is drawn under: the one in the pane that created its
/// worktree, while it lives, is no task itself and shares the project. A
/// worktree Claude Code's hook made names the pane that then works in it,
/// which is the task itself, not a parent.
fn creatorOf(sources: FleetSources, entries: []const FleetEntry, entry: FleetEntry) ?u8 {
    if (entry.card == .agent) {
        return null;
    }

    const agent = &sources.agents[entry.index];
    const row = taskRow(sources.workspaces, agent) orelse return null;
    if (row.coordinator) |reference| {
        for (entries) |candidate| {
            const parent = &sources.agents[candidate.index];
            if (candidate.index != entry.index and candidate.card == .agent and candidate.project == entry.project and parent.key.pane_id == reference.pane_id and parent.key.pane_generation == reference.pane_generation and std.mem.eql(u8, &parent.session_id, &reference.session_id)) {
                return candidate.index;
            }
        }

        return null;
    }

    const pane = row.created_by orelse return null;
    if (pane == agent.key.pane_id) {
        return null;
    }

    for (entries) |candidate| {
        if (candidate.card == .agent and candidate.project == entry.project and sources.agents[candidate.index].key.pane_id == pane) {
            return candidate.index;
        }
    }

    return null;
}

fn projectOf(workspaces: *const data.WorkspaceListSnapshot, agent: *const data.Agent) ?core.WorkspaceId {
    if (workspaces.worktree(agent.work_tree)) |row| {
        return row.source;
    }

    const workspace = switch (agent.location.workspace) {
        .workspace => |id| id,
        .worktree => return null,
    };
    const project = workspaces.projectOf(workspace);
    return if (workspaces.indexOf(project) != null) project else null;
}

fn projectRank(workspaces: *const data.WorkspaceListSnapshot, project: ?core.WorkspaceId) usize {
    const id = project orelse return std.math.maxInt(usize);
    return workspaces.indexOf(id) orelse std.math.maxInt(usize);
}

fn lessThan(sources: FleetSources, left: FleetEntry, right: FleetEntry) bool {
    const left_rank = projectRank(sources.workspaces, left.project);
    const right_rank = projectRank(sources.workspaces, right.project);
    if (left_rank != right_rank) {
        return left_rank < right_rank;
    }

    // An orphan task has no agent to follow, so orphans close the group.
    const left_orphan = left.card != .agent and left.creator == null;
    const right_orphan = right.card != .agent and right.creator == null;
    if (left_orphan != right_orphan) {
        return !left_orphan;
    }

    if (!left_orphan) {
        // Trees in the attention order of their roots; a root before its tasks.
        const left_root = left.creator orelse left.index;
        const right_root = right.creator orelse right.index;
        if (left_root != right_root) {
            return attention.compare(&sources.agents[left_root], &sources.agents[right_root]) == .lt;
        }

        if ((left.card == .agent) != (right.card == .agent)) {
            return left.card == .agent;
        }
    }

    if ((left.card == .task_full) != (right.card == .task_full)) {
        return left.card == .task_full;
    }

    return attention.compare(&sources.agents[left.index], &sources.agents[right.index]) == .lt;
}

fn testingAgent(pane: u64, workspace: u64, status: core.AgentStatus) !data.Agent {
    return try data.Agent.init(.{
        .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(workspace) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .claude,
        .status = status,
    });
}

test "tasks without a creator close their project group, needing ones first" {
    var snapshot: data.WorkspaceListSnapshot = .{};
    _ = try snapshot.replace(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
            .{ .workspace = @enumFromInt(5), .name = "fix", .path = "/w/fix", .tab_count = 1 },
            .{ .workspace = @enumFromInt(6), .name = "links", .path = "/w/links", .tab_count = 1 },
        },
        .worktrees = &.{
            .{ .worktree = @enumFromInt(1), .source = @enumFromInt(1), .workspace = @enumFromInt(5), .branch = "fix" },
            .{ .worktree = @enumFromInt(2), .source = @enumFromInt(1), .workspace = @enumFromInt(6), .branch = "links" },
        },
    });
    const agents = [_]data.Agent{
        try testingAgent(10, 2, .working),
        try testingAgent(11, 5, .working),
        try testingAgent(12, 1, .ready),
        try testingAgent(13, 6, .blocked),
    };

    var storage: [max_entries]FleetEntry = undefined;
    const fleet = order(.{ .agents = &agents, .workspaces = &snapshot }, &storage);
    try std.testing.expectEqual(@as(u8, 2), fleet[0].index);
    try std.testing.expectEqual(FleetCard.agent, fleet[0].card);
    try std.testing.expect(fleet[0].first_in_project);
    try std.testing.expectEqual(@as(u8, 3), fleet[1].index);
    try std.testing.expectEqual(FleetCard.task_full, fleet[1].card);
    try std.testing.expectEqual(@as(u8, 1), fleet[2].index);
    try std.testing.expectEqual(FleetCard.task_compact, fleet[2].card);
    try std.testing.expectEqual(@as(u8, 0), fleet[3].index);
    try std.testing.expect(fleet[3].first_in_project);

    const focused = order(.{ .agents = &agents, .workspaces = &snapshot, .focused = @enumFromInt(11) }, &storage);
    for (focused) |entry| {
        if (entry.index == 1) {
            try std.testing.expectEqual(FleetCard.task_full, entry.card);
        }
    }
}

test "a task hangs under the agent whose pane created it, and one without a live creator under no one" {
    var snapshot: data.WorkspaceListSnapshot = .{};
    _ = try snapshot.replace(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 2 },
            .{ .workspace = @enumFromInt(5), .name = "qa", .path = "/w/qa", .tab_count = 1 },
            .{ .workspace = @enumFromInt(6), .name = "setup", .path = "/w/setup", .tab_count = 1 },
            .{ .workspace = @enumFromInt(7), .name = "hook", .path = "/w/hook", .tab_count = 1 },
        },
        .worktrees = &.{
            .{ .worktree = @enumFromInt(1), .source = @enumFromInt(1), .workspace = @enumFromInt(5), .created_by = @enumFromInt(20), .branch = "qa" },
            // Its creator's pane closed.
            .{ .worktree = @enumFromInt(2), .source = @enumFromInt(1), .workspace = @enumFromInt(6), .created_by = @enumFromInt(99), .branch = "setup" },
            // Claude Code's WorktreeCreate hook names the pane that then works there.
            .{ .worktree = @enumFromInt(3), .source = @enumFromInt(1), .workspace = @enumFromInt(7), .created_by = @enumFromInt(23), .branch = "hook" },
        },
    });
    const agents = [_]data.Agent{
        // The coordinator works and comes first; another session of the
        // project waits. Grouping every task after the project's agents put
        // the coordinator's task under that other session.
        try testingAgent(20, 1, .working),
        try testingAgent(21, 1, .ready),
        try testingAgent(22, 5, .working),
        try testingAgent(24, 6, .working),
        try testingAgent(23, 7, .working),
    };

    var storage: [max_entries]FleetEntry = undefined;
    const fleet = order(.{ .agents = &agents, .workspaces = &snapshot }, &storage);
    const expected = [_]u8{ 0, 2, 1, 4, 3 };
    for (expected, fleet) |index, entry| {
        try std.testing.expectEqual(index, entry.index);
    }

    try std.testing.expectEqual(@as(?u8, 0), fleet[1].creator);
    for ([_]usize{ 0, 2, 3, 4 }) |position| {
        try std.testing.expectEqual(@as(?u8, null), fleet[position].creator);
    }
}
