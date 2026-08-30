//! Application command for renaming a workspace aggregate.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const RenameWorkspace = struct {
    location: schema.WorkspaceLocation,
    /// Borrowed only for the synchronous `execute` call.
    name: []const u8,
};

pub const RenameWorkspaceResult = workspace_mod.WorkspaceRenamed;

pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.WorkspaceRenamed) void,
};

pub const RenameWorkspaceExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, RenameWorkspace) anyerror!RenameWorkspaceResult,

    /// Executes a workspace rename through the bound application handler.
    ///
    /// ```zig
    /// const renamed = try executor.execute(.{ .location = location, .name = "backend" });
    /// ```
    pub fn execute(executor: RenameWorkspaceExecutor, command: RenameWorkspace) !RenameWorkspaceResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const RenameWorkspaceHandler = struct {
    workspaces: *WorkspaceRepository,
    events: EventPublisher,

    /// Commits an aggregate rename and repository revision before publishing
    /// the owned workspace event. Failed commands have no effects.
    ///
    /// ```zig
    /// const renamed = try handler.execute(.{ .location = location, .name = "backend" });
    /// ```
    pub fn execute(handler: *RenameWorkspaceHandler, command: RenameWorkspace) !RenameWorkspaceResult {
        const renamed = try workspace_mod.renameWorkspace(
            handler.workspaces,
            command.location,
            command.name,
        );

        handler.events.publish(handler.events.context, renamed);
        return renamed;
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *RenameWorkspaceHandler) RenameWorkspaceExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: RenameWorkspace) !RenameWorkspaceResult {
        const handler: *RenameWorkspaceHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const EventCapture = struct {
    reader: workspace_mod.Reader,
    count: usize = 0,
    last: ?workspace_mod.WorkspaceRenamed = null,
    observed_committed_state: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        const committed_name = capture.reader.workspaceName(event.location) orelse return;

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_state = std.mem.eql(u8, committed_name, event.nameSlice());
    }
};

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

test "RenameWorkspaceHandler commits before publishing one owned event" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    var requested_name = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };

    const renamed = try handler.executor().execute(.{
        .location = location,
        .name = &requested_name,
    });
    @memset(&requested_name, 'x');

    try std.testing.expectEqualStrings("backend", workspaces.reader().workspaceName(location).?);
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(location, capture.last.?.location);
    try std.testing.expectEqualStrings("backend", capture.last.?.nameSlice());
    try std.testing.expectEqualStrings("backend", renamed.nameSlice());
}

test "RenameWorkspaceHandler rejects missing targets and invalid names without effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = "",
    }));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = &oversized,
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .workspace = try schema.id.workspace(999) },
        .name = "missing",
    }));

    try std.testing.expectEqualStrings("project", workspaces.reader().workspaceName(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
