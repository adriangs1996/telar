//! A workspace's panes use the default colors of the client that holds its
//! geometry lease. Spectators declare colors but never impose them.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientKey = @import("../history/ClientKey.zig");
const geometry_lease = @import("geometry_lease.zig");

/// Receives a client's declared colors and applies them where it holds the
/// geometry lease.
///
/// ```zig
/// terminal_colors.configure(model, session, colors);
/// ```
pub fn configure(model: *RuntimeModel, session: *Session, colors: core.TerminalColors) void {
    if (!session.setTerminalColors(colors)) {
        return;
    }

    var rows = model.workspaces.reserved.iterator(.{});
    while (rows.next()) |slot| {
        const holder = model.workspaces.lease[slot] orelse continue;
        if (std.meta.eql(holder, session.key)) {
            apply(model, .{ .workspace = model.workspaces.id[slot] }, session.key);
        }
    }
}

/// The colors a new pane in `workspace` starts with.
/// Example: `const colors = terminal_colors.ofWorkspace(model, location.workspace);`.
pub fn ofWorkspace(model: *RuntimeModel, workspace: core.WorkspaceLocation) core.TerminalColors {
    const holder = geometry_lease.owner(model, workspace) orelse return .{};
    const session = model.clients.resolve(holder) orelse return .{};
    return session.terminal_colors;
}

/// Sets the lease holder's colors on every pane of the workspace.
/// Example: `terminal_colors.apply(model, workspace, holder);`.
pub fn apply(model: *RuntimeModel, workspace: core.WorkspaceLocation, key: ClientKey) void {
    const session = model.clients.resolve(key) orelse return;
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location.workspace, workspace)) {
            pane.setTerminalColors(session.terminal_colors);
        }
    }
}
