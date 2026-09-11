//! Application transaction for creating a workspace and its root pane.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;
pub const WorkspaceRepository = workspace_mod.Repository;

pub const CreateWorkspace = @import("CreateWorkspace.zig");

pub const CreateWorkspaceResult = @import("CreateWorkspaceResult.zig");

pub const PrepareLaunch = @import("CreateWorkspacePrepareLaunch.zig");

pub const LaunchPane = @import("CreateWorkspaceLaunchPane.zig");

pub const LaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");

pub const LaunchAuthority = @import("CreateWorkspaceLaunchAuthority.zig");

pub const GeometryLease = @import("CreateWorkspaceGeometryLease.zig");

pub const PaneLauncher = @import("CreateWorkspacePaneLauncher.zig");

pub const ClientAttachment = @import("ClientAttachment.zig");

pub const EventPublisher = @import("CreateWorkspaceEventPublisher.zig");

pub const CreateWorkspaceExecutor = @import("CreateWorkspaceExecutor.zig");

pub const CreateWorkspaceHandler = @import("CreateWorkspaceHandler.zig");

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}

const AuthorityCapture = @import("CreateWorkspaceAuthorityCapture.zig");

const GeometryCapture = @import("CreateWorkspaceGeometryCapture.zig");

const LauncherCapture = @import("CreateWorkspaceLauncherCapture.zig");

const AttachmentCapture = @import("CreateWorkspaceAttachmentCapture.zig");

const EventCapture = @import("CreateWorkspaceEventCapture.zig");

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
