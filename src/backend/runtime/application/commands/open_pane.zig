//! Application transaction for selecting, launching, and attaching a pane.

const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const LaunchViewType = @import("telar-core").LaunchView;
const TabLocationType = @import("telar-core").TabLocation;
const pane_module = @import("telar-core").pane;
const RepositoryType = @import("../../../workspace/Repository.zig");
const TestingPorts = @import("TestingPorts.zig");
const OpenPaneHandler = @import("OpenPaneHandler.zig");
const StateType = @import("../../../workspace/State.zig");
const std = @import("std");
const PanesCapture = @import("PanesCapture.zig");
const OpenPaneAuthorityCapture = @import("OpenPaneAuthorityCapture.zig");
const OpenPaneGeometryCapture = @import("OpenPaneGeometryCapture.zig");
const OpenPaneEventCapture = @import("OpenPaneEventCapture.zig");
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const OpenPane = @import("OpenPane.zig");
const raw_module = @import("telar-core").raw;

pub const RuntimeEvent = union(enum) {
    workspace_created: WorkspaceCreatedType,
    pane_launched: PaneLaunchedType,
};

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

fn testingPane(location: TabLocationType) !PaneLaunchedType {
    return .{
        .key = .{ .id = try pane_module(17), .generation = 9 },
        .location = location,
    };
}

fn testingHandler(workspaces: *RepositoryType, ports: TestingPorts) OpenPaneHandler {
    return .{
        .workspaces = workspaces,
        .panes = ports.panes.port(),
        .authority = ports.authority.port(),
        .geometry = ports.geometry.port(),
        .events = ports.events.publisher(),
    };
}

test "OpenPaneHandler attaches an explicit pane and prepares it only with geometry" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .pane_result = active };
    var authority: OpenPaneAuthorityCapture = .{};
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .first_result = active };
    var authority: OpenPaneAuthorityCapture = .{};
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
        .target = .{ .workspace = try workspace_module(999) },
        .size = .{ .cols = 120, .rows = 40 },
        .launch = null,
    }));
}

test "OpenPaneHandler reuses a default pane without launch effects" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const active = try testingPane(location);
    var panes: PanesCapture = .{ .first_result = active };
    var authority: OpenPaneAuthorityCapture = .{};
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    const proposed_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{ .launch_result = launched };
    var authority: OpenPaneAuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var panes: PanesCapture = .{};
    var authority: OpenPaneAuthorityCapture = .{ .failure = error.InvalidLaunchCwd };
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
        var state: StateType = .{};
        var workspaces = RepositoryType.init(&state, std.testing.allocator);
        defer workspaces.deinit();
        var panes: PanesCapture = .{ .launch_failure = case.launch_error };
        var authority: OpenPaneAuthorityCapture = .{ .cwd = "/work/new" };
        var geometry: OpenPaneGeometryCapture = .{};
        var events: OpenPaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const revision = workspaces.reader().revision();
    var panes: PanesCapture = .{ .launch_failure = error.OutOfMemory };
    var authority: OpenPaneAuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
    try std.testing.expectEqual(@as(u64, 1), raw_module(workspace_id));
}

test "OpenPaneHandler validates default launch and preserves committed effects" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const proposed_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{
        .launch_result = launched,
        .attach_failure = error.AttachmentUnavailable,
    };
    var authority: OpenPaneAuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const proposed_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const launched = try testingPane(proposed_location);
    var panes: PanesCapture = .{
        .launch_result = launched,
        .view_failure = error.ViewUnavailable,
    };
    var authority: OpenPaneAuthorityCapture = .{ .cwd = "/work/new" };
    var geometry: OpenPaneGeometryCapture = .{};
    var events: OpenPaneEventCapture = .{};
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
