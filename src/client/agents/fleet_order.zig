//! The fleet order both sidebars draw: agents grouped by project in project
//! list order; inside a group the agents of the project's own checkout (the
//! coordinator) first, then its tasks, the agents working in its worktrees.
//! Each part keeps the shared attention order. A task that needs the person
//! (blocked, failed, finished unseen) or is selected is drawn in full; the
//! rest take one line. See `docs/flows/task-cards.md`.

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

    const left_task = left.card != .agent;
    const right_task = right.card != .agent;
    if (left_task != right_task) {
        return !left_task;
    }

    if (left_task and (left.card == .task_full) != (right.card == .task_full)) {
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

test "tasks hang under their project after its own agents, needing ones first" {
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
