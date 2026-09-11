//! Application transaction for launching a sibling pane in an existing tab.

const LaunchViewType = @import("telar-core").LaunchView;
const TabLocationType = @import("telar-core").TabLocation;
const CreatePane = @import("CreatePane.zig");
const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const pane_module = @import("telar-core").pane;
const CreatePaneCapture = @import("CreatePaneCapture.zig");
const CreatePaneAuthorityCapture = @import("CreatePaneAuthorityCapture.zig");
const CreatePaneLauncherCapture = @import("CreatePaneLauncherCapture.zig");
const CreatePaneAttachmentCapture = @import("CreatePaneAttachmentCapture.zig");
const CreatePaneEventCapture = @import("CreatePaneEventCapture.zig");
const CreatePaneHandler = @import("CreatePaneHandler.zig");
const tab_module = @import("telar-core").tab;

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

fn testingLaunch() LaunchViewType {
    return .{
        .cwd = "/requested",
        .argument_count = 1,
        .encoded_arguments = "\x07\x00/bin/sh",
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

fn testingCommand(location: TabLocationType) CreatePane {
    return .{
        .location = location,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = testingLaunch(),
    };
}

fn testingRepository(state: *StateType) RepositoryType {
    return RepositoryType.init(state, std.testing.allocator);
}

fn testingLaunched(location: TabLocationType) !PaneLaunchedType {
    return .{
        .key = .{ .id = try pane_module(17), .generation = 9 },
        .location = location,
    };
}

test "CreatePaneHandler publishes the committed pane before attaching" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: CreatePaneCapture = .{};
    var authority: CreatePaneAuthorityCapture = .{};
    var launcher: CreatePaneLauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: CreatePaneAttachmentCapture = .{};
    var events: CreatePaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const existing = (try workspaces.ensure("/work/project")).location;
    var panes: CreatePaneCapture = .{ .has_running = false };
    var authority: CreatePaneAuthorityCapture = .{};
    var launcher: CreatePaneLauncherCapture = .{ .result = try testingLaunched(existing) };
    var attachment: CreatePaneAttachmentCapture = .{};
    var events: CreatePaneEventCapture = .{};
    var handler: CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = panes.port(),
        .authority = authority.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };
    const missing: TabLocationType = .{
        .workspace = existing.workspace,
        .tab_id = try tab_module(999),
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: CreatePaneCapture = .{};
    var authority: CreatePaneAuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var launcher: CreatePaneLauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: CreatePaneAttachmentCapture = .{};
    var events: CreatePaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: CreatePaneCapture = .{};
    var authority: CreatePaneAuthorityCapture = .{};
    var launcher: CreatePaneLauncherCapture = .{
        .failure = spawn_failure,
        .result = try testingLaunched(location),
    };
    var attachment: CreatePaneAttachmentCapture = .{};
    var events: CreatePaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: CreatePaneCapture = .{};
    var authority: CreatePaneAuthorityCapture = .{};
    var launcher: CreatePaneLauncherCapture = .{ .result = try testingLaunched(location) };
    var attachment: CreatePaneAttachmentCapture = .{ .failure = error.AttachmentUnavailable };
    var events: CreatePaneEventCapture = .{};
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
