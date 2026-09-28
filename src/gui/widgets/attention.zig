//! How agent attention reaches the chrome: the colour of one status, the
//! agent behind one pane, and the most urgent agent of a tab or workspace
//! through the shared comparator, so a dot on a tab and a pill agree with
//! the sidebar order. Pure lookups over the projected replica; no state.
const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const WorkspaceLoad = @import("WorkspaceLoad.zig");

/// One colour per meaning, the same in every surface.
/// Example: `const color = attention.statusColor(palette, agent.status);`
pub fn statusColor(palette: data.Palette, status: core.AgentStatus) cellgrid.Color {
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
pub fn paneAgent(projection: *const client.Projection, location: core.TabLocation, pane_id: core.PaneId) ?*const data.Agent {
    const key = projection.agents.keyForPane(location, pane_id) orelse return null;
    return projection.agents.find(key);
}

/// The status colour of the agent in one pane when it needs the person; null
/// for a plain shell or an agent that is working, done or idle.
/// Example: `const dot = attention.paneDot(projection, palette, location, pane_id);`
pub fn paneDot(projection: *const client.Projection, palette: data.Palette, location: core.TabLocation, pane_id: core.PaneId) ?cellgrid.Color {
    return dotColor(palette, paneAgent(projection, location, pane_id));
}

/// The status colour of a tab's most urgent agent when that agent needs the
/// person; null when nothing in the tab is blocked or failed.
/// Example: `const dot = attention.tabDot(projection, palette, tab.location);`
pub fn tabDot(projection: *const client.Projection, palette: data.Palette, location: core.TabLocation) ?cellgrid.Color {
    return dotColor(palette, tabAgent(projection, location));
}

/// The status colour of a workspace's most urgent agent when it needs the
/// person; every tab of the workspace counts.
/// Example: `const dot = attention.workspaceDot(projection, palette, id);`
pub fn workspaceDot(projection: *const client.Projection, palette: data.Palette, workspace: core.WorkspaceId) ?cellgrid.Color {
    var urgent: ?*const data.Agent = null;
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

/// The status colour of the most urgent agent needing the person in the
/// workspaces at list positions `range[0]..range[1]`, so an overflow control
/// keeps the attention of the workspaces it hides.
/// Example: `const dot = attention.listRangeDot(projection, palette, .{ 0, first });`
pub fn listRangeDot(projection: *const client.Projection, palette: data.Palette, range: [2]usize) ?cellgrid.Color {
    var urgent: ?*const data.Agent = null;
    for (projection.agents.slice()) |*agent| {
        if (!needsInput(agent.status)) {
            continue;
        }

        const id = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        const index = projection.workspaces.indexOf(id) orelse continue;
        if (index < range[0] or index >= range[1]) {
            continue;
        }

        urgent = mostUrgent(urgent, agent);
    }

    return dotColor(palette, urgent);
}

/// How many agents a workspace runs and how many of them need the person.
/// Example: `const load = attention.workspaceLoad(projection, id);`
pub fn workspaceLoad(projection: *const client.Projection, workspace: core.WorkspaceId) WorkspaceLoad {
    var load: WorkspaceLoad = .{};
    for (projection.agents.slice()) |*agent| {
        const owner = switch (agent.location.workspace) {
            .workspace => |id| id,
            .worktree => continue,
        };
        if (owner != workspace) {
            continue;
        }

        load.agents += 1;
        if (needsInput(agent.status)) {
            load.waiting += 1;
        }
    }

    return load;
}

/// The most urgent agent of one tab whatever its status, so a tab can show
/// work in progress and finished work as well as a request for input.
/// Example: `const agent = attention.tabAgent(projection, tab.location) orelse return;`
pub fn tabAgent(projection: *const client.Projection, location: core.TabLocation) ?*const data.Agent {
    var urgent: ?*const data.Agent = null;
    for (projection.agents.slice()) |*agent| {
        if (!std.meta.eql(agent.location, location)) {
            continue;
        }

        urgent = mostUrgent(urgent, agent);
    }

    return urgent;
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

fn mostUrgent(current: ?*const data.Agent, candidate: *const data.Agent) *const data.Agent {
    const previous = current orelse return candidate;
    return if (client.agent_attention.compare(candidate, previous) == .lt) candidate else previous;
}

fn dotColor(palette: data.Palette, urgent: ?*const data.Agent) ?cellgrid.Color {
    const agent = urgent orelse return null;
    if (!needsInput(agent.status)) {
        return null;
    }

    return statusColor(palette, agent.status);
}
