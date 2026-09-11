const Repository = @import("../../../workspace/Repository.zig");
const Panes = @import("Panes.zig");
const OpenPaneLaunchAuthority = @import("OpenPaneLaunchAuthority.zig");
const OpenPaneGeometryLease = @import("OpenPaneGeometryLease.zig");
const OpenPaneEventPublisher = @import("OpenPaneEventPublisher.zig");
const OpenPane = @import("OpenPane.zig");
const OpenPaneResult = @import("OpenPaneResult.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const OpenPaneExecutor = @import("OpenPaneExecutor.zig");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const Proposal = @import("../../../workspace/Proposal.zig");
const open_pane = @import("open_pane.zig");
const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const OpenPaneHandler = @This();

workspaces: *Repository,
panes: Panes,
authority: OpenPaneLaunchAuthority,
geometry: OpenPaneGeometryLease,
events: OpenPaneEventPublisher,

/// Selects an existing pane by pane or workspace, or atomically reuses or
/// launches the default pane for a launch cwd. New workspaces stay
/// invisible until pane launch commits. A geometry owner prepares the
/// selected view before every client attachment.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *OpenPaneHandler, command: OpenPane) !OpenPaneResult {
    var created = false;
    const active = switch (command.target) {
        .pane => |pane_id| handler.panes.find(handler.panes.context, pane_id) orelse return error.PaneNotFound,
        .workspace => |workspace_id| workspace: {
            const workspace_location: WorkspaceLocationType = .{ .workspace = workspace_id };
            const tab_id = handler.workspaces.reader().defaultTab(workspace_location) orelse return error.WorkspaceNotFound;
            const location: TabLocationType = .{
                .workspace = workspace_location,
                .tab_id = tab_id,
            };
            break :workspace handler.panes.first(handler.panes.context, location) orelse return error.WorkspaceHasNoPane;
        },
        .default => try handler.openDefault(command, &created),
    };

    if (handler.geometry.acquire(handler.geometry.context, active.location.workspace)) {
        try handler.panes.prepare_view(handler.panes.context, .{
            .pane = active,
            .size = command.size,
        });
    }

    try handler.panes.attach(handler.panes.context, active);
    return .{ .pane = active, .created = created };
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *OpenPaneHandler) OpenPaneExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn openDefault(handler: *OpenPaneHandler, command: OpenPane, created: *bool) !PaneLaunchedType {
    const launch = command.launch orelse return error.InvalidOpenRequest;
    const launch_cwd = try handler.authority.prepare(handler.authority.context, .{ .launch = launch });
    var proposal: ?Proposal = null;
    defer if (proposal) |*candidate| {
        candidate.rollback();
    };

    const location = handler.workspaces.reader().locationByPath(launch_cwd) orelse location: {
        proposal = handler.workspaces.propose(.{ .path = launch_cwd }) catch return error.WorkspaceCreateFailed;
        break :location proposal.?.location();
    };

    if (handler.panes.first(handler.panes.context, location)) |existing| {
        return existing;
    }

    var provisional_lease = false;
    var committed = false;
    defer if (!committed and provisional_lease and proposal != null) {
        handler.geometry.release(handler.geometry.context, location.workspace);
    };

    if (!handler.geometry.acquire(handler.geometry.context, location.workspace)) {
        return error.GeometryUnavailable;
    }
    provisional_lease = true;

    const workspace_path = if (proposal) |*candidate|
        candidate.path()
    else
        handler.workspaces.reader().workspacePath(location.workspace).?;
    const launched = handler.panes.launch(handler.panes.context, .{
        .location = location,
        .size = command.size,
        .launch = launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace_path,
    }) catch |err| return open_pane.mapLaunchError(err);

    if (proposal) |*candidate| {
        const workspace_created = WorkspaceCreatedType.init(location, candidate.name()) catch unreachable;
        _ = candidate.commit();
        handler.events.publish(handler.events.context, .{ .workspace_created = workspace_created });
    }

    committed = true;
    created.* = true;
    handler.events.publish(handler.events.context, .{ .pane_launched = launched });
    return launched;
}

fn executeErased(context: *anyopaque, command: OpenPane) !OpenPaneResult {
    const handler: *OpenPaneHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
