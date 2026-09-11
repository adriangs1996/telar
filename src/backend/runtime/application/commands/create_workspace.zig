//! Application transaction for creating a workspace and its root pane.

const LaunchViewType = @import("telar-core").LaunchView;
const CreateWorkspace = @import("CreateWorkspace.zig");
const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const CreateWorkspaceAuthorityCapture = @import("CreateWorkspaceAuthorityCapture.zig");
const CreateWorkspaceGeometryCapture = @import("CreateWorkspaceGeometryCapture.zig");
const CreateWorkspaceLauncherCapture = @import("CreateWorkspaceLauncherCapture.zig");
const pane_module = @import("telar-core").pane;
const CreateWorkspaceAttachmentCapture = @import("CreateWorkspaceAttachmentCapture.zig");
const CreateWorkspaceEventCapture = @import("CreateWorkspaceEventCapture.zig");
const CreateWorkspaceHandler = @import("CreateWorkspaceHandler.zig");
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const raw_module = @import("telar-core").raw;
const state_support = @import("../../../workspace/state_support.zig");

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

fn testingLaunch(cwd: []const u8) LaunchViewType {
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial_revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };
    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');

    try std.testing.expectError(error.WorkspaceCreateFailed, handler.execute(testingCommand(&oversized)));

    const inserted = try workspaces.insert(.{ .path = "/work/reused" });
    const workspace_id = switch (inserted.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    try std.testing.expectEqual(@as(u64, 1), raw_module(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), raw_module(inserted.tab_id));
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
}

test "CreateWorkspaceHandler reports repository capacity before runtime effects" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();

    while (workspaces.reader().count() < state_support.max_workspaces) {
        _ = try workspaces.insert(.{ .path = "/work/full" });
    }

    const revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
    var handler: CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = authority.port(),
        .geometry = geometry.port(),
        .launcher = launcher.port(),
        .attachment = attachment.port(),
        .events = events.publisher(),
    };

    try std.testing.expectError(error.WorkspaceCreateFailed, handler.execute(testingCommand("overflow")));

    try std.testing.expectEqual(state_support.max_workspaces, workspaces.reader().count());
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), geometry.acquire_count);
    try std.testing.expectEqual(@as(usize, 0), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    try std.testing.expectEqual(@as(usize, 0), attachment.call_count);
}

test "CreateWorkspaceHandler rolls back when geometry is unavailable" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{ .available = false };
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{
        .failure = spawn_failure,
        .pane_id = try pane_module(17),
    };
    var attachment: CreateWorkspaceAttachmentCapture = .{};
    var events: CreateWorkspaceEventCapture = .{ .reader = workspaces.reader(), .initial_revision = revision };
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
    try std.testing.expectEqual(@as(u64, 1), raw_module(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), raw_module(inserted.tab_id));
}

test "CreateWorkspaceHandler rolls back every pane launch failure category" {
    try expectLaunchFailure(error.PaneLimitReached, error.PaneLimitReached);
    try expectLaunchFailure(error.UnsupportedEnvironment, error.UnsupportedEnvironment);
    try expectLaunchFailure(error.OutOfMemory, error.PaneSpawnFailed);
}

test "CreateWorkspaceHandler preserves committed state after attachment failure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var authority: CreateWorkspaceAuthorityCapture = .{};
    var geometry: CreateWorkspaceGeometryCapture = .{};
    var launcher: CreateWorkspaceLauncherCapture = .{ .pane_id = try pane_module(17) };
    var attachment: CreateWorkspaceAttachmentCapture = .{ .failure = error.AttachmentUnavailable };
    var events: CreateWorkspaceEventCapture = .{
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
