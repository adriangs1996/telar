//! A client splits a tab: the runtime launches a sibling pane in that tab
//! and attaches the requesting client to it.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const launch_cwd = @import("client/launch_cwd.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_launch = @import("pane_launch.zig");
const resync_required = @import("resync_required.zig");

/// Launches a pane beside the tab's existing ones and attaches to it.
///
/// ```zig
/// try pane_split.split(model, session, request);
/// ```
pub fn split(model: *RuntimeModel, session: *Session, request: core.CreatePaneView) !void {
    const pane = launchSibling(model, session, request) catch |err| {
        return switch (err) {
            error.TabNotFound => client_request.fail(session, request.request_id, .pane_not_found, "tab not found"),
            error.GeometryUnavailable => client_request.fail(session, request.request_id, .resource_limit, "workspace geometry is leased by another client"),
            error.InvalidLaunchCwd => client_request.fail(session, request.request_id, .invalid_request, "cwd source pane is unavailable"),
            error.PaneLimitReached, error.TabPaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, pane_launch.limitFailure(err).?),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, request.request_id, .spawn_failed, reason) else err,
        };
    };

    try session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = pane.id,
        .location = pane.location,
        .created = true,
    } });
}

fn launchSibling(model: *RuntimeModel, session: *Session, request: core.CreatePaneView) !*Pane {
    const workspaces = &model.workspaces;

    if (!workspaces.contains(request.location)) {
        return error.TabNotFound;
    }

    if (model.panes.countAt(request.location) == 0) {
        return error.TabNotFound;
    }

    if (!geometry_lease.acquire(model, session.key, request.location.workspace)) {
        return error.GeometryUnavailable;
    }

    const cwd = launch_cwd.resolveLaunchCwd(model, session, request.launch, .{ .tab = request.location }) catch return error.InvalidLaunchCwd;
    const workspace_path = workspaces.workspacePath(request.location.workspace) orelse return error.TabNotFound;
    const launched = pane_launch.launch(model, .{
        .location = request.location,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = cwd,
        .workspace_path = workspace_path,
    }) catch |err| return pane_launch.requestError(err);

    resync_required.notify(model, .{ .origin = session.key, .workspace = launched.location.workspace });
    _ = try pane_attachment.attach(model, session, launched);
    return launched;
}
