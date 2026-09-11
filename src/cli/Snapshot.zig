const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const ControlAgent = @import("ControlAgent.zig");
const values = @import("arguments/values.zig");
const std = @import("std");
const control = @import("control.zig");
const Snapshot = @This();

revision: u64 = 0,
entries: [max_agent_snapshot_entries]ControlAgent = undefined,
count: usize = 0,

pub fn slice(snapshot: *const Snapshot) []const ControlAgent {
    return snapshot.entries[0..snapshot.count];
}

/// Finds the unique agent named by a CLI target. `current` reads
/// `TELAR_PANE_ID`; a name matches the session title case-insensitively.
///
/// ```zig
/// const agent = try snapshot.resolve(target, environ) orelse return error.AgentNotFound;
/// ```
pub fn resolve(snapshot: *const Snapshot, target: values.Target, environ: std.process.Environ) !?*const ControlAgent {
    const wanted_pane: ?u64 = switch (target) {
        .current => try control.currentPaneId(environ),
        .pane => |pane| pane,
        .name => null,
    };

    if (wanted_pane) |pane_id| {
        for (snapshot.slice()) |*agent| {
            if (agent.pane_id == pane_id) {
                return agent;
            }
        }

        return null;
    }

    const name = std.mem.span(target.name);
    var found: ?*const ControlAgent = null;
    for (snapshot.slice()) |*agent| {
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
