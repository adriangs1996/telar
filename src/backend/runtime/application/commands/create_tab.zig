//! Application transaction for creating a tab and its root pane.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;
pub const WorkspaceRepository = workspace_mod.Repository;

pub const CreateTab = @import("CreateTab.zig");

pub const CreateTabResult = @import("CreateTabResult.zig");

pub const PrepareLaunch = @import("CreateTabPrepareLaunch.zig");

pub const LaunchPane = @import("CreateTabLaunchPane.zig");

pub const LaunchedPane = @import("CreateTabLaunchedPane.zig");

pub const LaunchAuthority = @import("CreateTabLaunchAuthority.zig");

pub const PaneAttachment = @import("CreateTabPaneAttachment.zig");

pub const PaneLauncher = @import("CreateTabPaneLauncher.zig");

pub const EventPublisher = @import("CreateTabEventPublisher.zig");

pub const CreateTabExecutor = @import("CreateTabExecutor.zig");

pub const CreateTabHandler = @import("CreateTabHandler.zig");

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

const ClientCapture = @import("ClientCapture.zig");

const LauncherCapture = @import("CreateTabLauncherCapture.zig");

const EventCapture = @import("CreateTabEventCapture.zig");

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
