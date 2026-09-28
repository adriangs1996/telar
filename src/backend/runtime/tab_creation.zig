//! A client creates a tab: the runtime proposes the tab, launches its root
//! pane and commits the tab only after the pane launch commits. A control
//! client launches one the same way, in the background: nobody is attached
//! to it and no client's focus moves to it.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const PendingTabCreated = @import("delivery/PendingTabCreated.zig");
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const launch_cwd = @import("client/launch_cwd.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_launch = @import("pane_launch.zig");
const resync_required = @import("resync_required.zig");

/// Creates the tab and its root pane, then attaches the client to it.
///
/// ```zig
/// try tab_creation.create(model, session, request);
/// ```
pub fn create(model: *RuntimeModel, session: *Session, request: core.CreateTabView) !void {
    const pending = createTab(model, session, request) catch |err| {
        return switch (err) {
            error.WorkspaceNotFound => client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found"),
            error.TabLimitReached => client_request.fail(session, request.request_id, .resource_limit, "tab limit reached"),
            error.InvalidTabLabel => client_request.fail(session, request.request_id, .invalid_request, "invalid tab label"),
            error.GeometryUnavailable => client_request.fail(session, request.request_id, .resource_limit, "workspace geometry is leased by another client"),
            error.InvalidLaunchCwd => client_request.fail(session, request.request_id, .invalid_request, "cwd source pane is unavailable"),
            error.PaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, "pane limit reached"),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, request.request_id, .spawn_failed, reason) else err,
        };
    };

    try session.delivery.responses.push(.{ .tab_created = pending });
}

fn createTab(model: *RuntimeModel, session: *Session, request: core.CreateTabView) !PendingTabCreated {
    const workspaces = &model.workspaces;
    const slot = workspaces.slotOf(request.workspace) orelse return error.WorkspaceNotFound;

    if (!geometry_lease.acquire(model, session.key, request.workspace)) {
        return error.GeometryUnavailable;
    }

    const cwd = launch_cwd.resolveLaunchCwd(model, session, request.launch, .{ .workspace = request.workspace }) catch return error.InvalidLaunchCwd;
    const tab_id = try workspaces.nextTabId();
    const position = try workspaces.addTab(slot, tab_id, request.label);
    const created: core.TabLocation = .{ .workspace = request.workspace, .tab_id = tab_id };
    var committed = false;
    defer if (!committed) {
        std.debug.assert(workspaces.tab_count[slot] == position + 1);
        workspaces.tab_count[slot] -= 1;
    };

    const pane = pane_launch.launch(model, .{
        .location = created,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = cwd,
        .workspace_path = workspaces.path[slot],
    }) catch |err| return pane_launch.requestError(err);
    const root_pane_id = pane.id;
    const pane_generation = pane.generation;

    workspaces.recordTabCreated(tab_id);
    committed = true;
    session_checkpoint.noteChange(model);
    resync_required.notify(model, .{ .origin = session.key, .workspace = request.workspace });

    const running = model.panes.findRunning(root_pane_id) orelse return error.LaunchedPaneUnavailable;
    _ = try pane_attachment.attach(model, session, running);

    const label = workspaces.labelAt(slot, position);
    var pending: PendingTabCreated = .{
        .request_id = request.request_id,
        .location = created,
        .position = position,
        .label = undefined,
        .label_len = @intCast(label.len),
        .root_pane_id = root_pane_id,
        .pane_generation = pane_generation,
    };
    @memcpy(pending.label[0..label.len], label);
    return pending;
}

/// Opens a tab in a workspace for a sender that shows nothing, as `telar tab
/// create --background` does: no geometry lease is taken and nobody is
/// attached, so the clients showing the workspace list the tab and keep
/// their focus where it was.
///
/// ```zig
/// try tab_creation.launch(model, session, request);
/// ```
pub fn launch(model: *RuntimeModel, session: *Session, request: core.LaunchTabView) !void {
    const pane = launchTab(model, session, request) catch |err| {
        return switch (err) {
            error.WorkspaceNotFound => client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found"),
            error.InvalidLaunchCwd => client_request.fail(session, request.request_id, .invalid_request, "a background tab needs an explicit working directory"),
            error.TabLimitReached => client_request.fail(session, request.request_id, .resource_limit, "tab limit reached"),
            error.InvalidTabLabel => client_request.fail(session, request.request_id, .invalid_request, "invalid tab label"),
            error.PaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, "pane limit reached"),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, request.request_id, .spawn_failed, reason) else err,
        };
    };

    try session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = pane.id,
        .location = pane.location,
        .created = false,
        .pane_generation = pane.generation,
    } });
}

fn launchTab(model: *RuntimeModel, session: *const Session, request: core.LaunchTabView) !*Pane {
    const slot = model.workspaces.slotOf(.{ .workspace = request.workspace }) orelse return error.WorkspaceNotFound;
    if (request.launch.cwd_source != null) {
        return error.InvalidLaunchCwd;
    }

    return open(model, session, .{
        .workspace_slot = slot,
        .label = request.label,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = request.launch.cwd,
    });
}

/// A tab to add to a workspace, with the command its root pane runs.
const TabOpening = struct {
    workspace_slot: usize,
    label: []const u8,
    size: core.TerminalSize,
    launch: core.LaunchView,
    launch_cwd: []const u8,
};

/// Adds a tab and its root pane to a workspace without leasing its geometry
/// or attaching anyone, and tells the clients showing the workspace. The
/// tab exists only once its pane has started.
///
/// ```zig
/// const pane = try tab_creation.open(model, session, .{ .workspace_slot = slot, .label = "", .size = size, .launch = launch, .launch_cwd = path });
/// ```
pub fn open(model: *RuntimeModel, session: *const Session, opening: TabOpening) !*Pane {
    const workspaces = &model.workspaces;
    const tab_id = try workspaces.nextTabId();
    const position = try workspaces.addTab(opening.workspace_slot, tab_id, opening.label);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = workspaces.id[opening.workspace_slot] },
        .tab_id = tab_id,
    };
    var committed = false;
    defer if (!committed) {
        std.debug.assert(workspaces.tab_count[opening.workspace_slot] == position + 1);
        workspaces.tab_count[opening.workspace_slot] -= 1;
    };

    const pane = pane_launch.launch(model, .{
        .location = location,
        .size = opening.size,
        .launch = opening.launch,
        .launch_cwd = opening.launch_cwd,
        .workspace_path = workspaces.path[opening.workspace_slot],
    }) catch |err| return pane_launch.requestError(err);

    workspaces.recordTabCreated(tab_id);
    committed = true;
    session_checkpoint.noteChange(model);
    resync_required.notify(model, .{ .origin = session.key, .workspace = location.workspace });
    return pane;
}
