//! Application transaction for creating a tab and its root pane.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const CreateTab = struct {
    workspace: schema.WorkspaceLocation,
    /// Borrowed only for the synchronous `execute` call.
    label: []const u8,
    size: schema.TerminalSize,
    /// Every slice in this view is borrowed only for `execute`.
    launch: schema.LaunchView,
};

pub const CreateTabResult = struct {
    created: workspace_mod.TabCreated,
    root_pane_id: schema.PaneId,
};

pub const PrepareLaunch = struct {
    workspace: schema.WorkspaceLocation,
    launch: schema.LaunchView,
};

pub const LaunchPane = struct {
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    launch_cwd: []const u8,
    workspace_path: []const u8,
};

/// Stable identity returned after the runtime commits the root pane.
pub const LaunchedPane = struct {
    id: schema.PaneId,
};

pub const LaunchAuthority = struct {
    context: *anyopaque,
    /// Validates client authority and returns a cwd borrowed until this call
    /// to the handler completes.
    prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
};

pub const PaneAttachment = struct {
    context: *anyopaque,
    /// Projects the committed pane into the requesting client's attachments.
    attach: *const fn (*anyopaque, LaunchedPane) anyerror!void,
};

/// Pane launch port whose success is the runtime pane commit point.
pub const PaneLauncher = struct {
    context: *anyopaque,
    launch: *const fn (*anyopaque, LaunchPane) anyerror!LaunchedPane,
};

/// Synchronous post-commit port. Implementations may retain the owned event.
pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.TabCreated) void,
};

pub const CreateTabExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CreateTab) anyerror!CreateTabResult,

    /// Executes tab creation through the bound application handler.
    ///
    /// ```zig
    /// const result = try executor.execute(command);
    /// ```
    pub fn execute(executor: CreateTabExecutor, command: CreateTab) !CreateTabResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const CreateTabHandler = struct {
    workspaces: *WorkspaceRepository,
    authority: LaunchAuthority,
    launcher: PaneLauncher,
    attachment: PaneAttachment,
    events: EventPublisher,

    /// Creates a provisional aggregate tab, commits it only after its root
    /// pane is running, publishes the committed event, then attaches the
    /// requesting client. Pre-commit failures remove the provisional tab and
    /// leave the identity cursor unchanged; post-commit failures never remove
    /// runtime state.
    ///
    /// ```zig
    /// const result = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CreateTabHandler, command: CreateTab) !CreateTabResult {
        const workspace = handler.workspaces.find(command.workspace) orelse return error.WorkspaceNotFound;
        const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
            .workspace = command.workspace,
            .launch = command.launch,
        });
        const tab_id = try handler.workspaces.nextTabId();
        const created = try workspace.createTab(tab_id, command.label);
        var committed = false;

        defer if (!committed) {
            const removed = workspace.removeTab(tab_id);
            std.debug.assert(removed);
        };

        const launched = handler.launcher.launch(handler.launcher.context, .{
            .location = created.location,
            .size = command.size,
            .launch = command.launch,
            .launch_cwd = launch_cwd,
            .workspace_path = workspace.pathSlice(),
        }) catch |err| return mapLaunchError(err);

        handler.workspaces.recordTabCreated(tab_id);
        committed = true;
        handler.events.publish(handler.events.context, created);
        try handler.attachment.attach(handler.attachment.context, launched);

        return .{
            .created = created,
            .root_pane_id = launched.id,
        };
    }

    /// Erases the concrete handler behind the command interface consumed by
    /// request controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *CreateTabHandler) CreateTabExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: CreateTab) !CreateTabResult {
        const handler: *CreateTabHandler = @ptrCast(@alignCast(context));
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

const ClientCapture = struct {
    prepare_failure: ?anyerror = null,
    attach_failure: ?anyerror = null,
    launch_cwd: []const u8 = "/prepared",
    prepare_count: usize = 0,
    attach_count: usize = 0,
    last_workspace: ?schema.WorkspaceLocation = null,
    last_requested_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_requested_cwd_len: usize = 0,
    last_pane_id: schema.PaneId = .invalid,
    event_count: ?*const usize = null,
    event_observed_before_attach: bool = false,

    fn authority(capture: *ClientCapture) LaunchAuthority {
        return .{
            .context = capture,
            .prepare = prepareLaunch,
        };
    }

    fn attachment(capture: *ClientCapture) PaneAttachment {
        return .{ .context = capture, .attach = attach };
    }

    fn prepareLaunch(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
        const capture: *ClientCapture = @ptrCast(@alignCast(context));
        std.debug.assert(request.launch.cwd.len <= capture.last_requested_cwd.len);

        capture.prepare_count += 1;
        capture.last_workspace = request.workspace;
        capture.last_requested_cwd_len = request.launch.cwd.len;
        @memcpy(capture.last_requested_cwd[0..request.launch.cwd.len], request.launch.cwd);

        if (capture.prepare_failure) |failure| {
            return failure;
        }

        return capture.launch_cwd;
    }

    fn attach(context: *anyopaque, pane: LaunchedPane) !void {
        const capture: *ClientCapture = @ptrCast(@alignCast(context));

        capture.attach_count += 1;
        capture.last_pane_id = pane.id;

        if (capture.event_count) |count| {
            capture.event_observed_before_attach = count.* == 1;
        }

        if (capture.attach_failure) |failure| {
            return failure;
        }
    }

    fn requestedCwd(capture: *const ClientCapture) []const u8 {
        return capture.last_requested_cwd[0..capture.last_requested_cwd_len];
    }
};

const LauncherCapture = struct {
    failure: ?anyerror = null,
    pane_id: schema.PaneId = .invalid,
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,
    last_size: ?schema.TerminalSize = null,
    last_launch_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_launch_cwd_len: usize = 0,
    last_workspace_path: [schema.max_cwd_bytes]u8 = undefined,
    last_workspace_path_len: usize = 0,
    last_argument_count: u16 = 0,

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
        capture.last_argument_count = request.launch.argument_count;

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

const EventCapture = struct {
    reader: workspace_mod.Reader,
    initial_revision: u64,
    count: usize = 0,
    last: ?workspace_mod.TabCreated = null,
    observed_committed_state: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabCreated) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        const committed_label = capture.reader.tabLabel(event.location) orelse return;

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_state = capture.reader.revision() != capture.initial_revision and
            std.mem.eql(u8, committed_label, event.labelSlice());
    }
};

fn testingLaunch(cwd: []const u8) schema.LaunchView {
    return .{
        .cwd = cwd,
        .argument_count = 2,
        .encoded_arguments = "\x07\x00/bin/sh\x02\x00-l",
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

fn testingCommand(workspace: schema.WorkspaceLocation, label: []const u8) CreateTab {
    return .{
        .workspace = workspace,
        .label = label,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch("/requested"),
    };
}

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

test "CreateTabHandler commits state before publishing and attaching" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const initial_revision = workspaces.reader().revision();
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    client.event_count = &events.count;
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };
    var requested_label = [_]u8{ 'l', 'o', 'g', 's' };

    const result = try handler.executor().execute(testingCommand(initial.workspace, &requested_label));
    @memset(&requested_label, 'x');

    try std.testing.expectEqual(@as(usize, 2), workspaces.reader().totalTabs());
    try std.testing.expect(workspaces.reader().revision() != initial_revision);
    try std.testing.expectEqual(@as(u64, 3), schema.id.raw(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), client.prepare_count);
    try std.testing.expectEqualDeep(initial.workspace, client.last_workspace.?);
    try std.testing.expectEqualStrings("/requested", client.requestedCwd());
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqualDeep(result.created.location, launcher.last_location.?);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 120, .rows = 40 }, launcher.last_size.?);
    try std.testing.expectEqualStrings("/prepared", launcher.launchCwd());
    try std.testing.expectEqualStrings("/work/project", launcher.workspacePath());
    try std.testing.expectEqual(@as(u16, 2), launcher.last_argument_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expect(events.observed_committed_state);
    try std.testing.expectEqualStrings("logs", events.last.?.labelSlice());
    try std.testing.expectEqual(@as(usize, 1), client.attach_count);
    try std.testing.expect(client.event_observed_before_attach);
    try std.testing.expectEqual(result.root_pane_id, client.last_pane_id);
    try std.testing.expectEqualStrings("logs", result.created.labelSlice());
    try std.testing.expectEqualStrings("logs", workspaces.reader().tabLabel(result.created.location).?);
}

test "CreateTabHandler returns the aggregate generated label" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = workspaces.reader().revision(),
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };

    const result = try handler.execute(testingCommand(initial.workspace, ""));

    try std.testing.expectEqualStrings("tab 2", result.created.labelSlice());
    try std.testing.expectEqualStrings("tab 2", events.last.?.labelSlice());
    try std.testing.expectEqualStrings("tab 2", workspaces.reader().tabLabel(result.created.location).?);
}

test "CreateTabHandler rejects missing workspaces before client effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = workspaces.reader().revision(),
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };
    const missing: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(99) };

    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(testingCommand(missing, "logs")));

    try std.testing.expectEqual(@as(usize, 0), workspaces.reader().totalTabs());
    try std.testing.expectEqual(@as(usize, 0), client.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), client.attach_count);
}

fn expectPrepareFailure(prepare_failure: anyerror) !void {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const initial_revision = workspaces.reader().revision();
    var client: ClientCapture = .{ .prepare_failure = prepare_failure };
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };

    try std.testing.expectError(prepare_failure, handler.execute(testingCommand(initial.workspace, "logs")));

    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().totalTabs());
    try std.testing.expectEqual(initial_revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(u64, 2), schema.id.raw(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), client.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), client.attach_count);
}

test "CreateTabHandler leaves state untouched when client launch preparation fails" {
    try expectPrepareFailure(error.GeometryUnavailable);
    try expectPrepareFailure(error.InvalidLaunchCwd);
}

test "CreateTabHandler rejects aggregate validation failures before launch" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const initial_revision = workspaces.reader().revision();
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };
    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(testingCommand(initial.workspace, &oversized)));

    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().totalTabs());
    try std.testing.expectEqual(initial_revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), client.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), client.attach_count);
}

test "CreateTabHandler reports tab capacity without launching a pane" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;

    while (workspaces.reader().totalTabs() < workspace_mod.max_tabs_per_workspace) {
        const workspace = workspaces.find(initial.workspace).?;
        const tab_id = try workspaces.nextTabId();
        _ = try workspace.createTab(tab_id, "");
        workspaces.recordTabCreated(tab_id);
    }

    const full_revision = workspaces.reader().revision();
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = full_revision,
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.TabLimitReached, handler.execute(testingCommand(initial.workspace, "overflow")));

    try std.testing.expectEqual(workspace_mod.max_tabs_per_workspace, workspaces.reader().totalTabs());
    try std.testing.expectEqual(full_revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), client.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), client.attach_count);
}

fn expectLaunchFailure(spawn_failure: anyerror, command_failure: anyerror) !void {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const initial_revision = workspaces.reader().revision();
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{
        .failure = spawn_failure,
        .pane_id = try schema.id.pane(17),
    };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };

    try std.testing.expectError(command_failure, handler.execute(testingCommand(initial.workspace, "logs")));

    const rejected: schema.TabLocation = .{
        .workspace = initial.workspace,
        .tab_id = try schema.id.tab(2),
    };
    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().totalTabs());
    try std.testing.expect(workspaces.reader().contains(initial));
    try std.testing.expect(!workspaces.reader().contains(rejected));
    try std.testing.expectEqualStrings("main", workspaces.reader().tabLabel(initial).?);
    try std.testing.expectEqual(initial_revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(u64, 2), schema.id.raw(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), client.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), client.attach_count);
}

test "CreateTabHandler rolls back every pane launch failure category" {
    try expectLaunchFailure(error.PaneLimitReached, error.PaneLimitReached);
    try expectLaunchFailure(error.UnsupportedEnvironment, error.UnsupportedEnvironment);
    try expectLaunchFailure(error.OutOfMemory, error.PaneSpawnFailed);
}

test "CreateTabHandler never rolls back a committed tab after attachment failure" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const initial_revision = workspaces.reader().revision();
    var client: ClientCapture = .{ .attach_failure = error.AttachmentUnavailable };
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .initial_revision = initial_revision,
    };
    client.event_count = &events.count;
    var handler: CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.AttachmentUnavailable, handler.execute(testingCommand(initial.workspace, "logs")));

    try std.testing.expectEqual(@as(usize, 2), workspaces.reader().totalTabs());
    try std.testing.expect(workspaces.reader().revision() != initial_revision);
    try std.testing.expectEqual(@as(u64, 3), schema.id.raw(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expect(events.observed_committed_state);
    try std.testing.expectEqualStrings("logs", events.last.?.labelSlice());
    try std.testing.expectEqual(@as(usize, 1), client.attach_count);
    try std.testing.expect(client.event_observed_before_attach);
    try std.testing.expectEqualStrings("logs", workspaces.reader().tabLabel(events.last.?.location).?);
}
