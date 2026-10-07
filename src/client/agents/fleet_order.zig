//! The fleet order both sidebars draw: agents grouped by project in project
//! list order. Inside a group each agent of the project's own checkout is
//! followed by its tasks, the agents working in worktrees its pane created;
//! the tasks nobody alive created come last, under no one. Each part keeps
//! the shared attention order. A task that needs the person (blocked,
//! failed, finished unseen) or is selected is drawn in full; the rest take
//! one line.

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
