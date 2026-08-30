//! Application transaction for creating a workspace and its root pane.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const CreateWorkspace = struct {
    /// Borrowed only for the synchronous `execute` call.
    name: []const u8,
    size: schema.TerminalSize,
    /// Every slice in this view is borrowed only for `execute`.
    launch: schema.LaunchView,
};

pub const CreateWorkspaceResult = struct {
    created: workspace_mod.WorkspaceCreated,
    root_pane_id: schema.PaneId,
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

pub const LaunchedPane = struct {
    id: schema.PaneId,
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

pub const PaneLauncher = struct {
    context: *anyopaque,
    launch: *const fn (*anyopaque, LaunchPane) anyerror!LaunchedPane,
};

pub const ClientAttachment = struct {
    context: *anyopaque,
    replace: *const fn (*anyopaque, LaunchedPane) anyerror!void,
};

pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.WorkspaceCreated) void,
};

pub const CreateWorkspaceExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CreateWorkspace) anyerror!CreateWorkspaceResult,

    /// Executes workspace creation through the bound application handler.
    ///
    /// ```zig
    /// const result = try executor.execute(command);
    /// ```
    pub fn execute(executor: CreateWorkspaceExecutor, command: CreateWorkspace) !CreateWorkspaceResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const CreateWorkspaceHandler = struct {
    workspaces: *WorkspaceRepository,
    authority: LaunchAuthority,
    geometry: GeometryLease,
    launcher: PaneLauncher,
    attachment: ClientAttachment,
    events: EventPublisher,

    /// Creates an invisible workspace proposal, acquires its geometry lease,
    /// launches the root pane, then commits and publishes the aggregate before
    /// replacing client attachments. Pre-commit failures release all proposed
    /// state; post-commit failures preserve runtime state.
    ///
    /// ```zig
    /// const result = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CreateWorkspaceHandler, command: CreateWorkspace) !CreateWorkspaceResult {
        const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
            .launch = command.launch,
        });
        var proposal = handler.workspaces.propose(.{
            .path = launch_cwd,
            .explicit_name = command.name,
        }) catch return error.WorkspaceCreateFailed;
        defer proposal.rollback();

        const location = proposal.location();
        var lease_acquired = false;
        var committed = false;
        defer if (!committed and lease_acquired) {
            handler.geometry.release(handler.geometry.context, location.workspace);
        };

        if (!handler.geometry.acquire(handler.geometry.context, location.workspace)) {
            return error.GeometryUnavailable;
        }
        lease_acquired = true;

        const launched = handler.launcher.launch(handler.launcher.context, .{
            .location = location,
            .size = command.size,
            .launch = command.launch,
            .launch_cwd = launch_cwd,
            .workspace_path = proposal.path(),
        }) catch |err| return mapLaunchError(err);
        const created = workspace_mod.WorkspaceCreated.init(location, proposal.name()) catch unreachable;

        _ = proposal.commit();
        committed = true;
        handler.events.publish(handler.events.context, created);
        try handler.attachment.replace(handler.attachment.context, launched);

        return .{
            .created = created,
            .root_pane_id = launched.id,
        };
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *CreateWorkspaceHandler) CreateWorkspaceExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: CreateWorkspace) !CreateWorkspaceResult {
        const handler: *CreateWorkspaceHandler = @ptrCast(@alignCast(context));
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

const AuthorityCapture = struct {
    failure: ?anyerror = null,
    launch_cwd: []const u8 = "/prepared",
    call_count: usize = 0,
    last_requested_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_requested_cwd_len: usize = 0,

    fn port(capture: *AuthorityCapture) LaunchAuthority {
        return .{ .context = capture, .prepare = prepare };
    }

    fn prepare(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
        const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
        std.debug.assert(request.launch.cwd.len <= capture.last_requested_cwd.len);

        capture.call_count += 1;
        capture.last_requested_cwd_len = request.launch.cwd.len;
        @memcpy(capture.last_requested_cwd[0..request.launch.cwd.len], request.launch.cwd);

        if (capture.failure) |failure| {
            return failure;
        }

        return capture.launch_cwd;
    }

    fn requestedCwd(capture: *const AuthorityCapture) []const u8 {
        return capture.last_requested_cwd[0..capture.last_requested_cwd_len];
    }
};

const GeometryCapture = struct {
    available: bool = true,
    acquire_count: usize = 0,
    release_count: usize = 0,
    last_workspace: ?schema.WorkspaceLocation = null,

    fn port(capture: *GeometryCapture) GeometryLease {
        return .{
            .context = capture,
            .acquire = acquire,
            .release = release,
        };
    }

    fn acquire(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.acquire_count += 1;
        capture.last_workspace = workspace;
        return capture.available;
    }

    fn release(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.release_count += 1;
        capture.last_workspace = workspace;
    }
};

const LauncherCapture = struct {
    failure: ?anyerror = null,
    pane_id: schema.PaneId,
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,
    last_size: ?schema.TerminalSize = null,
    last_launch_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_launch_cwd_len: usize = 0,
    last_workspace_path: [schema.max_cwd_bytes]u8 = undefined,
    last_workspace_path_len: usize = 0,

    fn port(capture: *LauncherCapture) PaneLauncher {
        return .{ .context = capture, .launch = launch };
    }

    fn launch(context: *anyopaque, request: LaunchPane) !LaunchedPane {
        const capture: *LauncherCapture = @ptrCast(@alignCast(context));
        std.debug.assert(request.launch_cwd.len <= capture.last_launch_cwd.len);
        std.debug.assert(request.workspace_path.len <= capture.last_workspace_path.len);

        capture.call_count += 1;
        capture.last_location = request.location;
        capture.last_size = request.size;
        capture.last_launch_cwd_len = request.launch_cwd.len;
        @memcpy(capture.last_launch_cwd[0..request.launch_cwd.len], request.launch_cwd);
        capture.last_workspace_path_len = request.workspace_path.len;
        @memcpy(capture.last_workspace_path[0..request.workspace_path.len], request.workspace_path);

        if (capture.failure) |failure| {
            return failure;
        }

        return .{ .id = capture.pane_id };
    }

    fn launchCwd(capture: *const LauncherCapture) []const u8 {
        return capture.last_launch_cwd[0..capture.last_launch_cwd_len];
    }

    fn workspacePath(capture: *const LauncherCapture) []const u8 {
        return capture.last_workspace_path[0..capture.last_workspace_path_len];
    }
};

const AttachmentCapture = struct {
    failure: ?anyerror = null,
    event_count: ?*const usize = null,
    call_count: usize = 0,
    last_pane_id: schema.PaneId = .invalid,
    event_observed_before_replace: bool = false,

    fn port(capture: *AttachmentCapture) ClientAttachment {
        return .{ .context = capture, .replace = replace };
    }

    fn replace(context: *anyopaque, pane: LaunchedPane) !void {
        const capture: *AttachmentCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last_pane_id = pane.id;

        if (capture.event_count) |count| {
            capture.event_observed_before_replace = count.* == 1;
        }

        if (capture.failure) |failure| {
            return failure;
        }
    }
};

const EventCapture = struct {
    reader: workspace_mod.Reader,
    initial_revision: u64,
    count: usize = 0,
    last: ?workspace_mod.WorkspaceCreated = null,
    observed_committed_state: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.WorkspaceCreated) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        const committed_name = capture.reader.workspaceName(event.location.workspace) orelse return;

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_state = capture.reader.revision() != capture.initial_revision and
            std.mem.eql(u8, committed_name, event.nameSlice());
    }
};

fn testingLaunch(cwd: []const u8) schema.LaunchView {
    return .{
        .cwd = cwd,
        .argument_count = 1,
        .encoded_arguments = "\x07\x00/bin/sh",
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

fn testingCommand(name: []const u8) CreateWorkspace {
    return .{
        .name = name,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch("/requested"),
    };
}

test "CreateWorkspaceHandler commits before publishing and replacing attachments" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial_revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    attachment.event_count = &events.count;
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };
    var requested_name = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };

    const result = try handler.executor().execute(testingCommand(&requested_name));
    @memset(&requested_name, 'x');

    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().count());
    try std.testing.expect(workspaces.reader().revision() != initial_revision);
    try std.testing.expectEqualStrings("backend", workspaces.reader().workspaceName(result.created.location.workspace).?);
    try std.testing.expectEqualStrings("/prepared", workspaces.reader().workspacePath(result.created.location.workspace).?);
    try std.testing.expectEqualStrings("backend", result.created.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), authority.call_count);
    try std.testing.expectEqualStrings("/requested", authority.requestedCwd());
    try std.testing.expectEqual(@as(usize, 1), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
    try std.testing.expectEqualDeep(result.created.location.workspace, geometry.last_workspace.?);
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqualDeep(result.created.location, launcher.last_location.?);
    try std.testing.expectEqualStrings("/prepared", launcher.launchCwd());
    try std.testing.expectEqualStrings("/prepared", launcher.workspacePath());
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expect(events.observed_committed_state);
    try std.testing.expectEqualStrings("backend", events.last.?.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), attachment.call_count);
    try std.testing.expect(attachment.event_observed_before_replace);
    try std.testing.expectEqual(result.root_pane_id, attachment.last_pane_id);
}

test "CreateWorkspaceHandler stops before proposal when launch authority fails" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.InvalidLaunchCwd, handler.execute(testingCommand("backend")));

    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

test "CreateWorkspaceHandler maps proposal validation without consuming identity" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };
    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(error.WorkspaceCreateFailed, handler.execute(testingCommand(&oversized)));

    const inserted = try workspaces.insert(.{ .path = "/work/reused" });
    const workspace_id = switch (inserted.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(inserted.tab_id));
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
}

test "CreateWorkspaceHandler reports repository capacity before runtime effects" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();

    while (workspaces.reader().count() < workspace_mod.max_workspaces) {
        _ = try workspaces.insert(.{ .path = "/work/full" });
    }

    const revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.WorkspaceCreateFailed, handler.execute(testingCommand("overflow")));

    try std.testing.expectEqual(workspace_mod.max_workspaces, workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

test "CreateWorkspaceHandler rolls back when geometry is unavailable" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{ .available = false };
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.GeometryUnavailable, handler.execute(testingCommand("backend")));

    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
}

fn expectLaunchFailure(spawn_failure: anyerror, command_failure: anyerror) !void {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{
        .failure = spawn_failure,
        .pane_id = try schema.id.pane(17),
    };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(command_failure, handler.execute(testingCommand("backend")));

    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 1), geometry.release_count);
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);

    const inserted = try workspaces.insert(.{ .path = "/work/reused" });
    const workspace_id = switch (inserted.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(inserted.tab_id));
}

test "CreateWorkspaceHandler rolls back every pane launch failure category" {
    try expectLaunchFailure(error.PaneLimitReached, error.PaneLimitReached);
    try expectLaunchFailure(error.UnsupportedEnvironment, error.UnsupportedEnvironment);
    try expectLaunchFailure(error.OutOfMemory, error.PaneSpawnFailed);
}

test "CreateWorkspaceHandler preserves committed state after attachment failure" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var authority: AuthorityCapture = .{};
    var geometry: GeometryCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var attachment: AttachmentCapture = .{ .failure = error.AttachmentUnavailable };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = workspaces.reader().revision(),
    };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.AttachmentUnavailable, handler.execute(testingCommand("backend")));

    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().count());
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqual(@as(usize, 1), attachment.call_count);
    try std.testing.expectEqual(@as(usize, 0), geometry.release_count);
}
