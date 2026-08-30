//! Application transaction for launching a sibling pane in an existing tab.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

pub const CreatePane = struct {
    location: schema.TabLocation,
    size: schema.TerminalSize,
    /// Every slice in this view is borrowed only for `execute`.
    launch: schema.LaunchView,
};

pub const CreatePaneResult = pane_mod.PaneLaunched;

pub const PrepareLaunch = struct {
    location: schema.TabLocation,
    launch: schema.LaunchView,
};

pub const LaunchPane = struct {
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    launch_cwd: []const u8,
    workspace_path: []const u8,
};

pub const TabPanes = struct {
    context: *anyopaque,
    has_running: *const fn (*anyopaque, schema.TabLocation) bool,
};

pub const LaunchAuthority = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
};

pub const PaneLauncher = struct {
    context: *anyopaque,
    launch: *const fn (*anyopaque, LaunchPane) anyerror!pane_mod.PaneLaunched,
};

pub const PaneAttachment = struct {
    context: *anyopaque,
    attach: *const fn (*anyopaque, pane_mod.PaneLaunched) anyerror!void,
};

pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, pane_mod.PaneLaunched) void,
};

pub const CreatePaneExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CreatePane) anyerror!CreatePaneResult,

    /// Executes pane creation through the bound application handler.
    ///
    /// ```zig
    /// const launched = try executor.execute(command);
    /// ```
    pub fn execute(executor: CreatePaneExecutor, command: CreatePane) !CreatePaneResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const CreatePaneHandler = struct {
    workspaces: workspace_mod.Reader,
    panes: TabPanes,
    authority: LaunchAuthority,
    launcher: PaneLauncher,
    attachment: PaneAttachment,
    events: EventPublisher,

    /// Validates the live tab, resolves client launch authority, commits the
    /// pane through `PaneLauncher`, then publishes and attaches it. Once launch
    /// succeeds, later effect failures never withdraw the runtime-owned pane.
    ///
    /// ```zig
    /// const launched = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CreatePaneHandler, command: CreatePane) !CreatePaneResult {
        if (!handler.workspaces.contains(command.location)) {
            return error.TabNotFound;
        }

        if (!handler.panes.has_running(handler.panes.context, command.location)) {
            return error.TabNotFound;
        }

        const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
            .location = command.location,
            .launch = command.launch,
        });
        const workspace_path = handler.workspaces.workspacePath(command.location.workspace) orelse return error.TabNotFound;
        const launched = handler.launcher.launch(handler.launcher.context, .{
            .location = command.location,
            .size = command.size,
            .launch = command.launch,
            .launch_cwd = launch_cwd,
            .workspace_path = workspace_path,
        }) catch |err| return mapLaunchError(err);

        handler.events.publish(handler.events.context, launched);
        try handler.attachment.attach(handler.attachment.context, launched);
        return launched;
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *CreatePaneHandler) CreatePaneExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: CreatePane) !CreatePaneResult {
        const handler: *CreatePaneHandler = @ptrCast(@alignCast(context));
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

const PaneCapture = struct {
    has_running: bool = true,
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn port(capture: *PaneCapture) TabPanes {
        return .{ .context = capture, .has_running = hasRunning };
    }

    fn hasRunning(context: *anyopaque, location: schema.TabLocation) bool {
        const capture: *PaneCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last_location = location;
        return capture.has_running;
    }
};

const AuthorityCapture = struct {
    failure: ?anyerror = null,
    launch_cwd: []const u8 = "/prepared",
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn port(capture: *AuthorityCapture) LaunchAuthority {
        return .{ .context = capture, .prepare = prepare };
    }

    fn prepare(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
        const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last_location = request.location;

        if (capture.failure) |failure| {
            return failure;
        }

        return capture.launch_cwd;
    }
};

const LauncherCapture = struct {
    failure: ?anyerror = null,
    result: pane_mod.PaneLaunched,
    call_count: usize = 0,
    last_request: ?LaunchPane = null,

    fn port(capture: *LauncherCapture) PaneLauncher {
        return .{ .context = capture, .launch = launch };
    }

    fn launch(context: *anyopaque, request: LaunchPane) !pane_mod.PaneLaunched {
        const capture: *LauncherCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last_request = request;

        if (capture.failure) |failure| {
            return failure;
        }

        return capture.result;
    }
};

const AttachmentCapture = struct {
    failure: ?anyerror = null,
    event_count: ?*const usize = null,
    call_count: usize = 0,
    last: ?pane_mod.PaneLaunched = null,
    event_observed_before_attach: bool = false,

    fn port(capture: *AttachmentCapture) PaneAttachment {
        return .{ .context = capture, .attach = attach };
    }

    fn attach(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
        const capture: *AttachmentCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.last = launched;

        if (capture.event_count) |count| {
            capture.event_observed_before_attach = count.* == 1;
        }

        if (capture.failure) |failure| {
            return failure;
        }
    }
};

const EventCapture = struct {
    count: usize = 0,
    last: ?pane_mod.PaneLaunched = null,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, launched: pane_mod.PaneLaunched) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = launched;
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

fn testingCommand(location: schema.TabLocation) CreatePane {
    return .{
        .location = location,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    };
}

fn testingRepository(state: *workspace_mod.State) workspace_mod.Repository {
    return workspace_mod.Repository.init(state, std.testing.allocator);
}

fn testingLaunched(location: schema.TabLocation) !pane_mod.PaneLaunched {
    return .{
        .key = .{ .id = try schema.id.pane(17), .generation = 9 },
        .location = location,
    };
}

test "CreatePaneHandler publishes the committed pane before attaching" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{};
    var authority: AuthorityCapture = .{};
    var launcher: LauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{};
    attachment.event_count = &events.count;
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    const launched = try handler.executor().execute(testingCommand(location));

    try std.testing.expectEqualDeep(launcher.result, launched);
    try std.testing.expectEqual(@as(usize, 1), panes.call_count);
    try std.testing.expectEqualDeep(location, panes.last_location.?);
    try std.testing.expectEqual(@as(usize, 1), authority.call_count);
    try std.testing.expectEqualDeep(location, authority.last_location.?);
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqualDeep(location, launcher.last_request.?.location);
    try std.testing.expectEqualStrings("/prepared", launcher.last_request.?.launch_cwd);
    try std.testing.expectEqualStrings("/work/project", launcher.last_request.?.workspace_path);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(launched, events.last.?);
    try std.testing.expectEqual(@as(usize, 1), attachment.call_count);
    try std.testing.expect(attachment.event_observed_before_attach);
    try std.testing.expectEqualDeep(launched, attachment.last.?);
}

test "CreatePaneHandler rejects absent or pane-less tabs before authority effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const existing = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{ .has_running = false };
    var authority: AuthorityCapture = .{};
    var launcher: LauncherCapture = .{ .result = try testingLaunched(existing) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{};
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };
    const missing: schema.TabLocation = .{
        .workspace = existing.workspace,
        .tab_id = try schema.id.tab(999),
    };

    try std.testing.expectError(error.TabNotFound, handler.execute(testingCommand(missing)));
    try std.testing.expectEqual(@as(usize, 0), panes.call_count);
    try std.testing.expectError(error.TabNotFound, handler.execute(testingCommand(existing)));

    try std.testing.expectEqual(@as(usize, 1), panes.call_count);
    try std.testing.expectEqual(@as(usize, 0), authority.call_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

test "CreatePaneHandler leaves launch untouched when authority rejects the request" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{};
    var authority: AuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var launcher: LauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{};
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.InvalidLaunchCwd, handler.execute(testingCommand(location)));

    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

fn expectLaunchFailure(spawn_failure: anyerror, command_failure: anyerror) !void {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{};
    var authority: AuthorityCapture = .{};
    var launcher: LauncherCapture = .{
        .failure = spawn_failure,
        .result = try testingLaunched(location),
    };
    var attachment: AttachmentCapture = .{};
    var events: EventCapture = .{};
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(command_failure, handler.execute(testingCommand(location)));

    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

test "CreatePaneHandler maps every pane launch failure category" {
    try expectLaunchFailure(error.PaneLimitReached, error.PaneLimitReached);
    try expectLaunchFailure(error.UnsupportedEnvironment, error.UnsupportedEnvironment);
    try expectLaunchFailure(error.OutOfMemory, error.PaneSpawnFailed);
}

test "CreatePaneHandler preserves the launch event after attachment failure" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{};
    var authority: AuthorityCapture = .{};
    var launcher: LauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: AttachmentCapture = .{ .failure = error.AttachmentUnavailable };
    var events: EventCapture = .{};
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.AttachmentUnavailable, handler.execute(testingCommand(location)));

    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqual(@as(usize, 1), attachment.call_count);
}
