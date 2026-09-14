//! How agent attention reaches the chrome: the colour of one status, the
//! agent behind one pane, and the most urgent agent of a tab or workspace
//! through the shared comparator, so a dot on a tab and a pill agree with
//! the sidebar order. Pure lookups over the projected replica; no state.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");

/// One colour per meaning, the same in every surface.
/// Example: `const color = attention.statusColor(palette, agent.status);`
pub fn statusColor(palette: client.Palette, status: core.AgentStatus) core.Color {
    return switch (status) {
        .working => palette.teal,
        .ready, .done => palette.green,
        .blocked => palette.yellow,
        .failed => palette.red,
        .unknown => palette.overlay1,
    };
}

/// Whether a status asks for the person, per the comparator's first group.
/// Example: `if (attention.needsInput(agent.status)) ring = true;`
pub fn needsInput(status: core.AgentStatus) bool {
    return client.agent_attention.group(status) == .needs_input;
}

/// The agent whose current generation lives in `pane_id` of the tab at
/// `location`, or null for a plain shell.
/// Example: `const agent = attention.paneAgent(projection, location, pane_id) orelse return;`
pub fn paneAgent(projection: *const client.Projection, location: core.TabLocation, pane_id: core.PaneId) ?*const client.Agent {
    const key = projection.agents.keyForPane(location, pane_id) orelse return null;
    return projection.agents.find(key);
}

/// The status colour of a tab's most urgent agent when that agent needs the
/// person; null when nothing in the tab is blocked or failed.
/// Example: `const dot = attention.tabDot(projection, palette, tab.location);`
pub fn tabDot(projection: *const client.Projection, palette: client.Palette, location: core.TabLocation) ?core.Color {
    var urgent: ?*const client.Agent = null;
    for (projection.agents.slice()) |*agent| {
        if (!std.meta.eql(agent.location, location)) {
            continue;
        }

        urgent = mostUrgent(urgent, agent);
    }

    return dotColor(palette, urgent);
}

/// The status colour of a workspace's most urgent agent when it needs the
/// person; every tab of the workspace counts.
/// Example: `const dot = attention.workspaceDot(projection, palette, id);`
pub fn workspaceDot(projection: *const client.Projection, palette: client.Palette, workspace: core.WorkspaceId) ?core.Color {
    var urgent: ?*const client.Agent = null;
    for (projection.agents.slice()) |*agent| {
        const owner = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        if (owner != workspace) {
            continue;
        }

        urgent = mostUrgent(urgent, agent);
    }

    return dotColor(palette, urgent);
}

/// Formats an elapsed time the way the pane chip and the card show it.
/// Example: `const age = attention.ageLabel(&buffer, agent.statusAgeSeconds());`
pub fn ageLabel(buffer: []u8, seconds: u32) []const u8 {
    if (seconds < 60) {
        return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch "";
    }

    if (seconds < 3600) {
        return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60}) catch "";
    }

    return std.fmt.bufPrint(buffer, "{d}h", .{seconds / 3600}) catch "";
}

fn mostUrgent(current: ?*const client.Agent, candidate: *const client.Agent) *const client.Agent {
    const previous = current orelse return candidate;
    return if (client.agent_attention.compare(candidate, previous) == .lt) candidate else previous;
}

fn dotColor(palette: client.Palette, urgent: ?*const client.Agent) ?core.Color {
    const agent = urgent orelse return null;
    if (!needsInput(agent.status)) {
        return null;
    }

    return statusColor(palette, agent.status);
}
