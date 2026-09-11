//! Application transaction for launching a sibling pane in an existing tab.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../pane/root.zig");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;

pub const CreatePane = @import("CreatePane.zig");

pub const CreatePaneResult = pane_mod.PaneLaunched;

pub const PrepareLaunch = @import("CreatePanePrepareLaunch.zig");

pub const LaunchPane = @import("CreatePaneLaunchPane.zig");

pub const TabPanes = @import("TabPanes.zig");

pub const LaunchAuthority = @import("CreatePaneLaunchAuthority.zig");

pub const PaneLauncher = @import("CreatePanePaneLauncher.zig");

pub const PaneAttachment = @import("CreatePanePaneAttachment.zig");

pub const EventPublisher = @import("CreatePaneEventPublisher.zig");

pub const CreatePaneExecutor = @import("CreatePaneExecutor.zig");

pub const CreatePaneHandler = @import("CreatePaneHandler.zig");

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

const PaneCapture = @import("CreatePanePaneCapture.zig");

const AuthorityCapture = @import("CreatePaneAuthorityCapture.zig");

const LauncherCapture = @import("CreatePaneLauncherCapture.zig");

const AttachmentCapture = @import("CreatePaneAttachmentCapture.zig");

const EventCapture = @import("CreatePaneEventCapture.zig");

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
