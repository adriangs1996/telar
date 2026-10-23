//! A client holds a tab while it shows something there besides terminals,
//! such as another application's windows. A held tab outlives its last pane;
//! once no client holds it, or the clients holding it disconnect, a tab left
//! without panes goes as the last pane's exit would have taken it.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");
const tab_removal = @import("tab_removal.zig");
const worktree_lifecycle = @import("worktree_lifecycle.zig");

/// Holds or lets go of the tab for this client.
///
/// ```zig
/// try tab_hold.hold(model, session, request);
/// ```
pub fn hold(model: *RuntimeModel, session: *Session, request: core.HoldTab) !void {
    if (!model.workspaces.contains(request.location)) {
        return client_request.fail(session, request.request_id, .tab_not_found, "tab not found");
    }

    const index = find(session, request.location);
    if (request.held and index == null) {
        if (session.held_tab_count == session.held_tabs.len) {
            return client_request.fail(session, request.request_id, .resource_limit, "this client holds too many tabs");
        }

        session.held_tabs[session.held_tab_count] = request.location;
        session.held_tab_count += 1;
    }

    if (!request.held) {
        if (index) |found| {
            forget(session, found);
            release(model, request.location);
        }
    }

    try client_request.complete(session, request.request_id);
}

/// Whether any client holds the tab.
///
/// ```zig
/// if (!tab_hold.held(model, location)) { ... }
/// ```
pub fn held(model: *const RuntimeModel, location: core.TabLocation) bool {
    for (model.clients.items) |slot| {
        const session = slot orelse continue;
        if (!session.closing and find(session, location) != null) {
            return true;
        }
    }

    return false;
}

/// Lets go of every tab a disconnecting client held.
///
/// ```zig
/// tab_hold.releaseAll(model, session);
/// ```
pub fn releaseAll(model: *RuntimeModel, session: *Session) void {
    while (session.held_tab_count > 0) {
        const location = session.held_tabs[session.held_tab_count - 1];
        session.held_tab_count -= 1;
        release(model, location);
    }
}

fn find(session: *const Session, location: core.TabLocation) ?usize {
    for (session.held_tabs[0..session.held_tab_count], 0..) |candidate, index| {
        if (std.meta.eql(candidate, location)) {
            return index;
        }
    }

    return null;
}

fn forget(session: *Session, index: usize) void {
    session.held_tab_count -= 1;
    session.held_tabs[index] = session.held_tabs[session.held_tab_count];
}

/// Removes a tab that no pane and no client keeps any longer.
fn release(model: *RuntimeModel, location: core.TabLocation) void {
    if (model.panes.hasAt(location) or held(model, location) or !model.workspaces.contains(location)) {
        return;
    }

    const removed = model.workspaces.removeTab(model.gpa, location).?;
    tab_removal.announce(model, removed);
    if (removed.workspace_removed) {
        worktree_lifecycle.releaseWorkspace(model, removed.location.workspace);
    }
}
