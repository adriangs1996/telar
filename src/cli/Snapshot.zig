const Snapshot = @This();
const source_namespace = @import("control.zig");
const Agent = @import("ControlAgent.zig");
const parser = @import("parser.zig");
const std = @import("std");
revision: u64 = 0,
entries: [source_namespace.max_entries]Agent = undefined,
count: usize = 0,

pub fn slice(snapshot: *const Snapshot) []const Agent {
    return snapshot.entries[0..snapshot.count];
}

/// Finds the unique agent named by a CLI target. `current` reads
/// `TELAR_PANE_ID`; a name matches the session title case-insensitively.
///
/// ```zig
/// const agent = try snapshot.resolve(target, environ) orelse return error.AgentNotFound;
/// ```
pub fn resolve(snapshot: *const Snapshot, target: parser.Target, environ: std.process.Environ) !?*const Agent {
    const wanted_pane: ?u64 = switch (target) {
        .current => try source_namespace.currentPaneId(environ),
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
    var found: ?*const Agent = null;
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
