const core = @import("telar-core");
const ControlAgent = @import("ControlAgent.zig");
const values = @import("arguments/values.zig");
const std = @import("std");
const control = @import("control.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const Snapshot = @This();

revision: u64 = 0,
entries: [core.max_agent_snapshot_entries]ControlAgent = undefined,
count: usize = 0,
/// Worktrees a `worktree:` target resolves against; set by the caller.
catalog: ?*const WorktreeCatalog = null,

pub fn slice(self: *const Snapshot) []const ControlAgent {
    return self.entries[0..self.count];
}

/// Finds the unique agent named by a CLI target. `current` reads
/// `TELAR_PANE_ID`; a name matches the session title case-insensitively.
///
/// ```zig
/// const agent = try snapshot.resolve(target, environ) orelse return error.AgentNotFound;
/// ```
pub fn resolve(self: *const Snapshot, target: values.Target, environ: std.process.Environ) !?*const ControlAgent {
    const wanted_pane: ?u64 = switch (target) {
        .current => try control.currentPaneId(environ),
        .pane => |pane| pane,
        .name => null,
        .worktree => |reference| return self.resolveWorktree(std.mem.span(reference)),
    };

    if (wanted_pane) |pane_id| {
        for (self.slice()) |*agent| {
            if (agent.pane_id == pane_id) {
                return agent;
            }
        }

        return null;
    }

    const name = std.mem.span(target.name);
    var found: ?*const ControlAgent = null;
    for (self.slice()) |*agent| {
        if (!std.ascii.eqlIgnoreCase(agent.titleSlice(), name)) {
            continue;
        }
        if (found != null) {
            return error.AmbiguousAgentName;
        }

        found = agent;
    }

    return found;
}

/// The one agent working in the worktree `reference` names by branch or
/// title. A worktree holding several agents is ambiguous; use a pane id.
fn resolveWorktree(self: *const Snapshot, reference: []const u8) !?*const ControlAgent {
    const catalog = self.catalog orelse return error.WorktreeCatalogMissing;
    const worktree = try catalog.find(reference) orelse return error.WorktreeNotFound;
    var found: ?*const ControlAgent = null;
    for (self.slice()) |*agent| {
        if (agent.work_tree != core.raw(worktree.id)) {
            continue;
        }

        if (found != null) {
            return error.AmbiguousAgentName;
        }

        found = agent;
    }

    return found orelse error.WorktreeHasNoAgent;
}
