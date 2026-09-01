//! Application transaction for selecting, launching, and attaching a pane.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../pane/root.zig");
const workspace_mod = @import("../../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const OpenPane = struct {
    target: schema.PaneTarget,
    size: schema.TerminalSize,
    launch: ?schema.LaunchView,
};

pub const OpenPaneResult = struct {
    pane: pane_mod.PaneLaunched,
    created: bool,
};

pub const PrepareLaunch = struct {
    launch: schema.LaunchView,
};

pub const LaunchPane = struct {
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    launch_cwd: []const u8,
    workspace_path: []const u8,
};

pub const PrepareView = struct {
    pane: pane_mod.PaneLaunched,
    size: schema.TerminalSize,
};

pub const RuntimeEvent = union(enum) {
    workspace_created: workspace_mod.WorkspaceCreated,
    pane_launched: pane_mod.PaneLaunched,
};

pub const Panes = struct {
    context: *anyopaque,
    find: *const fn (*anyopaque, schema.PaneId) ?pane_mod.PaneLaunched,
    first: *const fn (*anyopaque, schema.TabLocation) ?pane_mod.PaneLaunched,
    launch: *const fn (*anyopaque, LaunchPane) anyerror!pane_mod.PaneLaunched,
    prepare_view: *const fn (*anyopaque, PrepareView) anyerror!void,
    attach: *const fn (*anyopaque, pane_mod.PaneLaunched) anyerror!void,
};

pub const LaunchAuthority = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
};

pub const GeometryLease = struct {
    context: *anyopaque,
    acquire: *const fn (*anyopaque, schema.WorkspaceLocation) bool,
    release: *const fn (*anyopaque, schema.WorkspaceLocation) void,
};

pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, RuntimeEvent) void,
};

pub const OpenPaneExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, OpenPane) anyerror!OpenPaneResult,

    /// Executes pane opening through the bound application handler.
    ///
    /// ```zig
    /// const result = try executor.execute(command);
    /// ```
    pub fn execute(executor: OpenPaneExecutor, command: OpenPane) !OpenPaneResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const OpenPaneHandler = struct {
    workspaces: *WorkspaceRepository,
    panes: Panes,
    authority: LaunchAuthority,
    geometry: GeometryLease,
    events: EventPublisher,

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
                const workspace_location: schema.WorkspaceLocation = .{ .workspace = workspace_id };
                const tab_id = handler.workspaces.reader().defaultTab(workspace_location) orelse return error.WorkspaceNotFound;
                const location: schema.TabLocation = .{
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

    fn openDefault(handler: *OpenPaneHandler, command: OpenPane, created: *bool) !pane_mod.PaneLaunched {
        const launch = command.launch orelse return error.InvalidOpenRequest;
        const launch_cwd = try handler.authority.prepare(handler.authority.context, .{ .launch = launch });
        var proposal: ?workspace_mod.WorkspaceProposal = null;
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
        }) catch |err| return mapLaunchError(err);

        if (proposal) |*candidate| {
            const workspace_created = workspace_mod.WorkspaceCreated.init(location, candidate.name()) catch unreachable;
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
};

fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

const PanesCapture = struct {
    pane_result: ?pane_mod.PaneLaunched = null,
    first_result: ?pane_mod.PaneLaunched = null,
    launch_result: ?pane_mod.PaneLaunched = null,
    launch_failure: ?anyerror = null,
    view_failure: ?anyerror = null,
    attach_failure: ?anyerror = null,
    find_count: usize = 0,
    first_count: usize = 0,
    launch_count: usize = 0,
    view_count: usize = 0,
    attach_count: usize = 0,
    last_launch: ?LaunchPane = null,
    last_view: ?PrepareView = null,

    fn port(capture: *PanesCapture) Panes {
        return .{
            .context = capture,
            .find = find,
            .first = first,
            .launch = launch,
            .prepare_view = prepareView,
            .attach = attach,
        };
    }

    fn find(context: *anyopaque, _: schema.PaneId) ?pane_mod.PaneLaunched {
        const capture: *PanesCapture = @ptrCast(@alignCast(context));
        capture.find_count += 1;
        return capture.pane_result;
    }

    fn first(context: *anyopaque, _: schema.TabLocation) ?pane_mod.PaneLaunched {
        const capture: *PanesCapture = @ptrCast(@alignCast(context));
        capture.first_count += 1;
        return capture.first_result;
    }

    fn launch(context: *anyopaque, request: LaunchPane) !pane_mod.PaneLaunched {
        const capture: *PanesCapture = @ptrCast(@alignCast(context));
        capture.launch_count += 1;
        capture.last_launch = request;

        if (capture.launch_failure) |failure| {
            return failure;
        }

        return capture.launch_result.?;
    }

    fn prepareView(context: *anyopaque, request: PrepareView) !void {
        const capture: *PanesCapture = @ptrCast(@alignCast(context));
        capture.view_count += 1;
        capture.last_view = request;

        if (capture.view_failure) |failure| {
            return failure;
        }
    }

    fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
        const capture: *PanesCapture = @ptrCast(@alignCast(context));
        capture.attach_count += 1;

        if (capture.attach_failure) |failure| {
            return failure;
        }
    }
};

const AuthorityCapture = struct {
    failure: ?anyerror = null,
    cwd: []const u8 = "/work/project",
    count: usize = 0,

    fn port(capture: *AuthorityCapture) LaunchAuthority {
        return .{ .context = capture, .prepare = prepare };
    }

    fn prepare(context: *anyopaque, _: PrepareLaunch) ![]const u8 {
        const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
        capture.count += 1;

        if (capture.failure) |failure| {
            return failure;
        }

        return capture.cwd;
    }
};

const GeometryCapture = struct {
    available: bool = true,
    acquire_count: usize = 0,
    release_count: usize = 0,

    fn port(capture: *GeometryCapture) GeometryLease {
        return .{
            .context = capture,
            .acquire = acquire,
            .release = release,
        };
    }

    fn acquire(context: *anyopaque, _: schema.WorkspaceLocation) bool {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.acquire_count += 1;
        return capture.available;
    }

    fn release(context: *anyopaque, _: schema.WorkspaceLocation) void {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.release_count += 1;
    }
};

const EventCapture = struct {
    events: [2]RuntimeEvent = undefined,
    len: usize = 0,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: RuntimeEvent) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.events[capture.len] = event;
        capture.len += 1;
    }
};

fn testingLaunch() schema.LaunchView {
    return .{
        .cwd = "/requested",
        .argument_count = 1,
        .encoded_arguments = "\x07\x00/bin/sh",
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

fn testingPane(location: schema.TabLocation) !pane_mod.PaneLaunched {
    return .{
        .key = .{ .id = try schema.id.pane(17), .generation = 9 },
        .location = location,
    };
}

const TestingPorts = struct {
    panes: *PanesCapture,
    authority: *AuthorityCapture,
    geometry: *GeometryCapture,
    events: *EventCapture,
};

fn testingHandler(workspaces: *WorkspaceRepository, ports: TestingPorts) OpenPaneHandler {
    return .{
        .workspaces = workspaces,
        .panes = ports.panes.port(),
        .authority = ports.authority.port(),
        .geometry = ports.geometry.port(),
        .events = ports.events.publisher(),
    };
}

test "OpenPaneHandler attaches an explicit pane and prepares it only with geometry" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .pane_result = active };
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    const result = try handler.execute(.{
        .target = .{ .pane = active.key.id },
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    });

    try std.testing.expectEqualDeep(active, result.pane);
    try std.testing.expect(!result.created);
    try std.testing.expectEqual(@as(usize, 1), panes.find_count);
    try std.testing.expectEqual(@as(usize, 1), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 1), panes.view_count);
    try std.testing.expectEqual(@as(usize, 1), panes.attach_count);
    try std.testing.expectEqual(@as(usize, 0), authority.count);
    try std.testing.expectEqual(@as(usize, 0), events.len);

    geometry.available = false;
    panes.view_count = 0;
    panes.attach_count = 0;
    _ = try handler.execute(.{
        .target = .{ .pane = active.key.id },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    });
    try std.testing.expectEqual(@as(usize, 0), panes.view_count);
    try std.testing.expectEqual(@as(usize, 1), panes.attach_count);
}

test "OpenPaneHandler resolves workspace targets and distinguishes their failures" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .first_result = active };
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });
    const workspace_id = switch (location.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };

    const result = try handler.execute(.{
        .target = .{ .workspace = workspace_id },
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    });
    try std.testing.expectEqualDeep(active, result.pane);

    panes.first_result = null;
    try std.testing.expectError(error.WorkspaceHasNoPane, handler.execute(.{
        .target = .{ .workspace = workspace_id },
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .target = .{ .workspace = try schema.id.workspace(999) },
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    }));
}

test "OpenPaneHandler reuses a default pane without launch effects" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .first_result = active };
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    const result = try handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    });

    try std.testing.expectEqualDeep(active, result.pane);
    try std.testing.expect(!result.created);
    try std.testing.expectEqual(@as(usize, 1), authority.count);
    try std.testing.expectEqual(@as(usize, 0), panes.launch_count);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "OpenPaneHandler commits a new default workspace only after pane launch" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    const proposed_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{ .launch_result = launched };
    var authority: AuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    const result = try handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    });

    try std.testing.expect(result.created);
    try std.testing.expectEqualDeep(launched, result.pane);
    try std.testing.expect(workspaces.reader().contains(proposed_location));
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 2), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 1), panes.launch_count);
    try std.testing.expectEqualStrings("/work/new", panes.last_launch.?.workspace_path);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(events.events[0] == .workspace_created);
    try std.testing.expect(events.events[1] == .pane_launched);
    try std.testing.expectEqualStrings("new", events.events[0].workspace_created.nameSlice());
    try std.testing.expectEqualDeep(launched, events.events[1].pane_launched);
    try std.testing.expectEqual(@as(usize, 1), panes.attach_count);
}

test "OpenPaneHandler stops before launch when authority or geometry rejects a new default" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var panes: PanesCapture = .{};
    var authority: AuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });
    const command: OpenPane = .{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    };

    try std.testing.expectError(error.InvalidLaunchCwd, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), panes.launch_count);

    authority.failure = null;
    geometry.available = false;

    try std.testing.expectError(error.GeometryUnavailable, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(@as(usize, 1), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 0), panes.launch_count);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "OpenPaneHandler maps launch failures and rolls back their provisional state" {
    const cases = [_]struct {
        launch_error: anyerror,
        expected: anyerror,
    }{
        .{ .launch_error = error.PaneLimitReached, .expected = error.PaneLimitReached },
        .{ .launch_error = error.UnsupportedEnvironment, .expected = error.UnsupportedEnvironment },
        .{ .launch_error = error.PermissionDenied, .expected = error.PaneSpawnFailed },
    };

    for (cases) |case| {
        var state: workspace_mod.State = .{};
        var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
        defer workspaces.deinit();
        var panes: PanesCapture = .{ .launch_failure = case.launch_error };
        var authority: AuthorityCapture = .{ .cwd = "/work/new" };
        var geometry: GeometryCapture = .{};
        var events: EventCapture = .{};
        var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

        try std.testing.expectError(case.expected, handler.execute(.{
            .target = .default,
            .size = .{ .cols = 120, .rows = 40 },
            .launch = testingLaunch(),
        }));

        try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
        try std.testing.expectEqual(@as(usize, 1), geometry.release_count);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }
}

test "OpenPaneHandler rolls back a new default workspace on launch failure" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var panes: PanesCapture = .{ .launch_failure = error.OutOfMemory };
    var authority: AuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    try std.testing.expectError(error.PaneSpawnFailed, handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    }));

    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 0), events.len);
    const inserted = try workspaces.insert(.{ .path = "/work/reused" });
    const workspace_id = switch (inserted.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(workspace_id));
}

test "OpenPaneHandler validates default launch and preserves committed effects" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const proposed_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{
        .launch_result = launched,
        .attach_failure = error.AttachmentUnavailable,
    };
    var authority: AuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    try std.testing.expectError(error.InvalidOpenRequest, handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    }));
    try std.testing.expectError(error.AttachmentUnavailable, handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    }));

    try std.testing.expect(workspaces.reader().contains(proposed_location));
    try std.testing.expectEqual(@as(usize, 2), events.len);
}

test "OpenPaneHandler keeps a committed launch when view preparation fails" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const proposed_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{
        .launch_result = launched,
        .view_failure = error.ViewUnavailable,
    };
    var authority: AuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: GeometryCapture = .{};
    var events: EventCapture = .{};
    var handler = testingHandler(&workspaces, .{ .panes = &panes, .authority = &authority, .geometry = &geometry, .events = &events });

    try std.testing.expectError(error.ViewUnavailable, handler.execute(.{
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    }));

    try std.testing.expect(workspaces.reader().contains(proposed_location));
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 1), panes.view_count);
    try std.testing.expectEqual(@as(usize, 0), panes.attach_count);
}
