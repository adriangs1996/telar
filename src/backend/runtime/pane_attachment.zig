//! A client attaches to a running pane, launching the workspace's first
//! pane when needed, and detaches from it again.

const pane_graphics = @import("pane_graphics.zig");
const pane_observation = @import("pane_observation.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const Attachment = @import("attachment/Attachment.zig");
const PaneDetached = @import("attachment/PaneDetached.zig");
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const launch_cwd = @import("client/launch_cwd.zig");
const pane_launch = @import("pane_launch.zig");
const resync_required = @import("resync_required.zig");

/// Attaches the client to the requested pane, or launches the workspace's
/// root pane for a default target. The lease holder resizes the pane.
///
/// ```zig
/// try pane_attachment.open(model, session, request);
/// ```
pub fn open(model: *RuntimeModel, session: *Session, request: core.OpenPaneView) !void {
    var created = false;
    const pane = attachTarget(model, session, request, &created) catch |err| {
        return switch (err) {
            error.PaneNotFound => client_request.fail(session, request.request_id, .pane_not_found, "pane not found"),
            error.WorkspaceNotFound => client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found"),
            error.WorkspaceHasNoPane => client_request.fail(session, request.request_id, .pane_not_found, "workspace has no running pane"),
            error.InvalidOpenRequest => client_request.fail(session, request.request_id, .invalid_request, "default pane launch is missing"),
            error.InvalidLaunchCwd => client_request.fail(session, request.request_id, .invalid_request, "cwd source pane is unavailable"),
            error.WorkspaceCreateFailed => client_request.fail(session, request.request_id, .resource_limit, "could not create workspace"),
            error.GeometryUnavailable => client_request.fail(session, request.request_id, .resource_limit, "workspace geometry is leased by another client"),
            error.PaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, "pane limit reached"),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            error.PaneResizeFailed => client_request.fail(session, request.request_id, .internal, "could not resize pane"),
            else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, request.request_id, .spawn_failed, reason) else err,
        };
    };

    try session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .location = pane.location,
        .created = created,
    } });
}

/// Ends the client's attachment to one pane.
///
/// ```zig
/// try pane_attachment.detach(model, session, request);
/// ```
pub fn detach(model: *RuntimeModel, session: *Session, request: core.DetachPane) !void {
    if (detachPane(model, session, request.pane_id) == null) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Detaches one pane and, when it was the client's last one, leaves its
/// workspace and releases the workspace's geometry lease.
///
/// ```zig
/// const detached = pane_attachment.detachPane(model, session, pane_id) orelse return;
/// ```
pub fn detachPane(model: *RuntimeModel, session: *Session, pane_id: core.PaneId) ?PaneDetached {
    const detached = release(model, session, pane_id) orelse return null;
    std.debug.assert(detached.pane_id == pane_id);

    if (!detached.last_attachment) {
        return detached;
    }

    const left_workspace = leaveWorkspace(model, session, detached.workspace);
    std.debug.assert(left_workspace);

    if (left_workspace) {
        geometry_lease.release(model, session.key, detached.workspace);
    }

    return detached;
}

/// Attaches the client to a running pane of the workspace it views, or of
/// any workspace when it views none yet. A pane already attached is
/// returned as it is.
///
/// ```zig
/// const attachment = try pane_attachment.attach(model, session, pane);
/// ```
pub fn attach(model: *RuntimeModel, session: *Session, pane: *Pane) !*Attachment {
    std.debug.assert(pane.launch_state == .running);
    if (model.attachments.find(session.slot, pane.id)) |existing| {
        return existing;
    }

    if (session.workspace) |workspace| {
        if (!std.meta.eql(workspace, pane.location.workspace)) {
            return error.WorkspaceMismatch;
        }
    }

    const attachment = try model.attachments.add(model.gpa, session.slot, pane);
    attachment.configureGraphics(session.shared_graphics);
    if (session.workspace == null) {
        session.workspace = pane.location.workspace;
    }

    return attachment;
}

/// Removes one attachment while the client keeps viewing its workspace. The
/// caller may need that view to publish lifecycle events before completing
/// departure with `leaveWorkspace`.
///
/// ```zig
/// const detached = pane_attachment.release(model, session, pane_id) orelse return;
/// if (detached.last_attachment) {
///     _ = pane_attachment.leaveWorkspace(model, session, detached.workspace);
/// }
/// ```
pub fn release(model: *RuntimeModel, session: *Session, pane_id: core.PaneId) ?PaneDetached {
    const attachment = model.attachments.find(session.slot, pane_id) orelse return null;
    const workspace = attachment.pane.location.workspace;
    std.debug.assert(session.observes(workspace));

    _ = model.attachments.remove(model.gpa, session.slot, pane_id);

    return .{
        .pane_id = pane_id,
        .workspace = workspace,
        .last_attachment = model.attachments.len(session.slot) == 0,
    };
}

/// Ends the client's view of a workspace it no longer attaches. A different
/// workspace, or one the client still attaches, is left unchanged.
///
/// ```zig
/// if (pane_attachment.leaveWorkspace(model, session, workspace)) {
///     geometry_lease.release(model, session.key, workspace);
/// }
/// ```
pub fn leaveWorkspace(model: *RuntimeModel, session: *Session, workspace: core.WorkspaceLocation) bool {
    if (model.attachments.len(session.slot) != 0 or !session.observes(workspace)) {
        return false;
    }

    session.workspace = null;
    return true;
}

/// Removes every attachment of the client and ends its workspace view,
/// keeping its graphics transport for the next workspace.
///
/// ```zig
/// pane_attachment.clear(model, session);
/// ```
pub fn clear(model: *RuntimeModel, session: *Session) void {
    model.attachments.clear(model.gpa, session.slot);
    session.workspace = null;
}

fn attachTarget(model: *RuntimeModel, session: *Session, request: core.OpenPaneView, created: *bool) !*Pane {
    const active = switch (request.target) {
        .pane => |pane_id| findOpenPane(model, pane_id) orelse return error.PaneNotFound,
        .workspace => |workspace_id| workspace: {
            const workspace_location: core.WorkspaceLocation = .{ .workspace = workspace_id };
            const tab_id = model.workspaces.defaultTab(workspace_location) orelse return error.WorkspaceNotFound;
            const location: core.TabLocation = .{
                .workspace = workspace_location,
                .tab_id = tab_id,
            };
            break :workspace model.panes.firstAt(location) orelse return error.WorkspaceHasNoPane;
        },
        .default => try openDefault(model, session, request, created),
    };

    if (geometry_lease.acquire(model, session.key, active.location.workspace)) {
        const resize_result = if (active.ingest_pending)
            active.requestResize(request.size)
        else
            active.resize(request.size);
        resize_result catch return error.PaneResizeFailed;
        try pane_observation.start(model, active);
        try pane_graphics.startMedia(model, active);
    }

    const attachment = try attach(model, session, active);
    _ = try attachment.resizeIfNeeded();
    return active;
}

fn findOpenPane(model: *RuntimeModel, pane_id: core.PaneId) ?*Pane {
    const pane = model.panes.findRunning(pane_id) orelse return null;
    if (pane.close_requested or pane.exit != null) {
        return null;
    }

    return pane;
}

fn openDefault(model: *RuntimeModel, session: *Session, request: core.OpenPaneView, created: *bool) !*Pane {
    const launch = request.launch orelse return error.InvalidOpenRequest;
    const cwd = launch_cwd.resolveLaunchCwd(model, session, launch, .any) catch return error.InvalidLaunchCwd;
    var proposal: ?usize = null;
    defer if (proposal) |slot| {
        model.workspaces.rollback(model.gpa, slot);
    };

    const location = model.workspaces.locationByPath(cwd) orelse location: {
        const slot = model.workspaces.propose(model.gpa, cwd, null) catch return error.WorkspaceCreateFailed;
        proposal = slot;
        break :location core.TabLocation{
            .workspace = .{ .workspace = model.workspaces.id[slot] },
            .tab_id = model.workspaces.tab_id[slot][0],
        };
    };

    if (model.panes.firstAt(location)) |existing| {
        return existing;
    }

    var provisional_lease = false;
    var committed = false;
    defer if (!committed and provisional_lease and proposal != null) {
        geometry_lease.release(model, session.key, location.workspace);
    };

    if (!geometry_lease.acquire(model, session.key, location.workspace)) {
        return error.GeometryUnavailable;
    }
    provisional_lease = true;

    const workspace_path = if (proposal) |slot|
        model.workspaces.path[slot]
    else
        model.workspaces.workspacePath(location.workspace).?;
    const launched = pane_launch.launch(model, .{
        .location = location,
        .size = request.size,
        .launch = launch,
        .launch_cwd = cwd,
        .workspace_path = workspace_path,
    }) catch |err| return pane_launch.requestError(err);

    if (proposal) |slot| {
        _ = model.workspaces.commit(slot);
        resync_required.notify(model, .{ .origin = session.key, .workspace = location.workspace });
    }

    committed = true;
    created.* = true;
    resync_required.notify(model, .{ .origin = session.key, .workspace = launched.location.workspace });
    return launched;
}
