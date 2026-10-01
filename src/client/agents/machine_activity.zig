//! Global activity order over borrowed machine replicas. Rebuilt on metadata
//! revisions, never on terminal frames; no remote terminal is attached here.
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const MachineActivity = @import("../machines/MachineActivity.zig");
const Machines = @import("../machines/Machines.zig");
const Entry = @import("MachineActivityEntry.zig");
const FleetEntry = @import("FleetEntry.zig");
const fleet_order = @import("fleet_order.zig");

pub const max_entries = Machines.capacity * (core.max_agent_snapshot_entries + core.max_worktree_entries);

/// Orders every machine's agents and tracked commands, nesting exact coordinator
/// matches across machines. Missing parents and cyclic attribution remain visible.
/// Example: `const entries = machine_activity.order(sources, active_slot, &storage);`
pub fn order(sources: []const MachineActivity, active_slot: u8, output: *[max_entries]Entry) []const Entry {
    var nodes: [max_entries]Entry = undefined;
    var count: usize = 0;
    for (sources, 0..) |source, source_index| {
        const model = source.model;
        const workspaces = &model.workspace_list_snapshot;
        const tab = if (source.slot == active_slot) model.tabs.activeSlot() else null;
        var local: [core.max_agent_snapshot_entries]FleetEntry = undefined;
        const fleet = fleet_order.order(.{
            .agents = model.agent_snapshot.slice(),
            .workspaces = workspaces,
            .focused = if (tab) |slot| model.tabs.layout[slot].focused() else null,
        }, &local);
        var represented: [core.max_worktree_entries]bool = @splat(false);
        for (fleet) |entry| {
            nodes[count] = .{
                .source = @intCast(source_index),
                .agent = entry.index,
                .project = entry.project,
                .card = entry.card,
            };
            if (fleet_order.taskRow(workspaces, &model.agent_snapshot.slice()[entry.index])) |row| {
                for (workspaces.worktrees[0..workspaces.worktree_count], 0..) |*candidate, index| {
                    if (candidate == row) {
                        represented[index] = true;
                        nodes[count].worktree = @intCast(index);
                        break;
                    }
                }
            }

            count += 1;
        }

        for (workspaces.worktrees[0..workspaces.worktree_count], 0..) |*row, index| {
            if (row.command_state == .none or represented[index]) {
                continue;
            }

            nodes[count] = .{
                .source = @intCast(source_index),
                .worktree = @intCast(index),
                .project = row.source,
                .card = .task_full,
            };
            count += 1;
        }
    }

    var agent_indices: [max_entries]u16 = undefined;
    var agent_count: usize = 0;
    for (nodes[0..count], 0..) |entry, index| {
        if (entry.agent != null) {
            agent_indices[agent_count] = @intCast(index);
            agent_count += 1;
        }
    }

    const lookup: IdentityLookup = .{ .sources = sources, .nodes = nodes[0..count] };
    std.sort.pdq(u16, agent_indices[0..agent_count], lookup, identityLessThan);
    for (nodes[0..count], 0..) |*entry, index| {
        entry.parent = parentOf(lookup, agent_indices[0..agent_count], index);
    }

    // Each parent chain is visited at most twice. Break only the cyclic edge,
    // keeping all cards without allowing hostile attribution to make O(n²) walks.
    const Visit = enum { unseen, visiting, finished };
    var visits: [max_entries]Visit = @splat(.unseen);
    var path: [max_entries]u16 = undefined;
    for (0..count) |start| {
        if (visits[start] == .finished) {
            continue;
        }

        var path_len: usize = 0;
        var current: ?u16 = @intCast(start);
        while (current) |index| {
            if (visits[index] != .unseen) {
                if (visits[index] == .visiting) {
                    nodes[index].parent = null;
                }

                break;
            }

            visits[index] = .visiting;
            path[path_len] = index;
            path_len += 1;
            current = nodes[index].parent;
        }

        for (path[0..path_len]) |index| {
            visits[index] = .finished;
        }
    }

    var first_child: [max_entries]?u16 = @splat(null);
    var last_child: [max_entries]?u16 = @splat(null);
    var next_sibling: [max_entries]?u16 = @splat(null);
    for (nodes[0..count], 0..) |entry, index| {
        if (entry.parent) |parent| {
            nodes[parent].coordinator = true;
            if (last_child[parent]) |last| {
                next_sibling[last] = @intCast(index);
            } else {
                first_child[parent] = @intCast(index);
            }

            last_child[parent] = @intCast(index);
        }
    }

    var positions: [max_entries]u16 = undefined;
    var len: usize = 0;
    var previous_source: ?u8 = null;
    var previous_project: ?core.WorkspaceId = null;
    for (nodes[0..count], 0..) |root, root_index| {
        if (root.parent != null) {
            continue;
        }

        var current: usize = root_index;
        var depth: u16 = 0;
        while (true) {
            var entry = nodes[current];
            entry.depth = depth;
            entry.parent = if (entry.parent) |parent| positions[parent] else null;
            positions[current] = @intCast(len);
            entry.first_in_project = depth == 0 and (len == 0 or previous_source != root.source or previous_project != root.project);
            output[len] = entry;
            len += 1;
            if (first_child[current]) |child| {
                current = child;
                depth += 1;
                continue;
            }

            while (current != root_index and next_sibling[current] == null) {
                current = nodes[current].parent.?;
                depth -= 1;
            }

            if (current == root_index) {
                break;
            }

            current = next_sibling[current].?;
        }

        previous_source = root.source;
        previous_project = root.project;
    }

    return output[0..len];
}

fn rowOf(source: MachineActivity, entry: Entry) ?*const data.WorktreeRow {
    const workspaces = &source.model.workspace_list_snapshot;
    if (entry.worktree) |index| {
        return &workspaces.worktrees[index];
    }

    return fleet_order.taskRow(workspaces, &source.model.agent_snapshot.slice()[entry.agent.?]);
}

const IdentityLookup = struct {
    sources: []const MachineActivity,
    nodes: []const Entry,
};

fn identityAt(lookup: IdentityLookup, index: usize) core.CoordinatorReference {
    const entry = lookup.nodes[index];
    const agent = &lookup.sources[entry.source].model.agent_snapshot.slice()[entry.agent.?];
    return .{ .session_id = agent.session_id, .pane_id = agent.key.pane_id, .pane_generation = agent.key.pane_generation };
}

fn identityOrder(left: core.CoordinatorReference, right: core.CoordinatorReference) std.math.Order {
    const session = std.mem.order(u8, &left.session_id, &right.session_id);
    if (session != .eq) {
        return session;
    }

    if (left.pane_id != right.pane_id) {
        return std.math.order(core.raw(left.pane_id), core.raw(right.pane_id));
    }

    return std.math.order(left.pane_generation, right.pane_generation);
}

fn identityLessThan(lookup: IdentityLookup, left: u16, right: u16) bool {
    const comparison = identityOrder(identityAt(lookup, left), identityAt(lookup, right));
    return if (comparison == .eq) left < right else comparison == .lt;
}

fn parentOf(lookup: IdentityLookup, agents: []const u16, index: usize) ?u16 {
    const entry = lookup.nodes[index];
    const source = lookup.sources[entry.source];
    const row = rowOf(source, entry) orelse return null;
    if (row.coordinator) |reference| {
        var low: usize = 0;
        var high = agents.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (identityOrder(identityAt(lookup, agents[middle]), reference) == .lt) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        // Two aliases of the same runtime may expose the same identity.
        // Resolve deterministically, never letting a card parent itself.
        while (low < agents.len and identityOrder(identityAt(lookup, agents[low]), reference) == .eq) : (low += 1) {
            if (agents[low] != index) {
                return agents[low];
            }
        }

        return null;
    }

    const pane = row.created_by orelse return null;
    var start = index;
    while (start != 0 and lookup.nodes[start - 1].source == entry.source) {
        start -= 1;
    }

    for (lookup.nodes[start..], start..) |candidate, parent| {
        if (candidate.source != entry.source) {
            break;
        }

        if (candidate.agent == null or parent == index) {
            continue;
        }

        const agent = &source.model.agent_snapshot.slice()[candidate.agent.?];
        if (candidate.card == .agent and candidate.project == entry.project and pane == agent.key.pane_id) {
            return @intCast(parent);
        }
    }

    return null;
}

fn testingAgent(session: u8, pane: u64, workspace: u64, status: core.AgentStatus) data.AgentInput {
    return .{
        .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 },
        .session_id = .{session} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(workspace) }, .tab_id = @enumFromInt(1) },
        .pane_index = 1,
        .provider = .codex,
        .status = status,
    };
}

test "remote children match full session identity and retain commands without duplicate agent cards" {
    const own = try std.testing.allocator.create(data.ClientModel);
    defer std.testing.allocator.destroy(own);
    own.* = data.ClientModel.init(std.testing.allocator, true);
    defer own.deinit();
    const remote = try std.testing.allocator.create(data.ClientModel);
    defer std.testing.allocator.destroy(remote);
    remote.* = data.ClientModel.init(std.testing.allocator, true);
    defer remote.deinit();
    _ = try own.agent_snapshot.replace(.{ .revision = 1, .agents = &.{testingAgent(1, 7, 1, .working)} });
    _ = try remote.agent_snapshot.replace(.{ .revision = 1, .agents = &.{
        testingAgent(2, 7, 1, .working),
        testingAgent(3, 8, 2, .blocked),
    } });
    const reference: core.CoordinatorReference = .{ .session_id = .{1} ** 16, .pane_id = @enumFromInt(7), .pane_generation = 1 };
    _ = try remote.workspace_list_snapshot.replace(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "repo", .path = "/repo", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "task", .path = "/task", .tab_count = 1 },
        },
        .worktrees = &.{
            .{ .worktree = @enumFromInt(1), .source = @enumFromInt(1), .workspace = @enumFromInt(2), .branch = "fix", .coordinator = reference, .command_state = .running },
            .{ .worktree = @enumFromInt(2), .source = @enumFromInt(1), .workspace = @enumFromInt(3), .branch = "tests", .coordinator = reference, .command_state = .exited, .command_exit = 1 },
        },
    });
    const sources = [_]MachineActivity{
        .{ .slot = 0, .label = "coordinator", .model = own, .connected = true },
        .{ .slot = 1, .label = "worker", .model = remote, .connected = false },
    };
    var storage: [max_entries]Entry = undefined;
    const entries = order(&sources, 0, &storage);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(entries[0].coordinator);
    try std.testing.expectEqual(@as(u8, 0), entries[0].source);
    try std.testing.expectEqual(@as(u8, 1), entries[1].source);
    try std.testing.expectEqual(@as(?u8, 1), entries[1].agent);
    try std.testing.expectEqual(@as(u16, 1), entries[1].depth);
    try std.testing.expectEqual(@as(?u16, 0), entries[1].parent);
    try std.testing.expect(entries[2].worktree != null);
    try std.testing.expectEqual(@as(u16, 1), entries[2].depth);
    try std.testing.expectEqual(@as(u16, 0), entries[3].depth);

    // A new coordinator generation cannot inherit the old task, even though
    // the worker happens to have exactly the same numeric pane id.
    own.agent_snapshot.items[0].key.pane_generation = 2;
    const orphaned = order(&sources, 0, &storage);
    for (orphaned) |entry| {
        try std.testing.expectEqual(@as(u16, 0), entry.depth);
    }
}

test "cyclic cross-machine attribution does not hide either task" {
    var model = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{ testingAgent(1, 1, 1, .working), testingAgent(2, 2, 2, .working) } });
    _ = try model.workspace_list_snapshot.replace(.{
        .revision = 1,
        .entries = &.{},
        .worktrees = &.{
            .{ .worktree = @enumFromInt(1), .source = @enumFromInt(10), .workspace = @enumFromInt(1), .branch = "one", .coordinator = .{ .session_id = .{2} ** 16, .pane_id = @enumFromInt(2), .pane_generation = 1 } },
            .{ .worktree = @enumFromInt(2), .source = @enumFromInt(10), .workspace = @enumFromInt(2), .branch = "two", .coordinator = .{ .session_id = .{1} ** 16, .pane_id = @enumFromInt(1), .pane_generation = 1 } },
        },
    });
    var storage: [max_entries]Entry = undefined;
    const entries = order(&.{.{ .slot = 0, .label = "box", .model = &model, .connected = true }}, 0, &storage);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u16, 0), entries[0].depth);
    try std.testing.expectEqual(@as(u16, 1), entries[1].depth);
}
