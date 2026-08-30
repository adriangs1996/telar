//! Application command for moving a tab inside its workspace aggregate.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const MoveTab = struct {
    location: schema.TabLocation,
    direction: schema.TabMoveDirection,
};

pub const MoveTabResult = workspace_mod.TabMoved;

pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.TabMoved) void,
};

pub const MoveTabExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, MoveTab) anyerror!MoveTabResult,

    /// Executes a tab move through the bound application handler.
    ///
    /// ```zig
    /// const moved = try executor.execute(.{ .location = location, .direction = .next });
    /// ```
    pub fn execute(executor: MoveTabExecutor, command: MoveTab) !MoveTabResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const MoveTabHandler = struct {
    workspaces: *WorkspaceRepository,
    events: EventPublisher,

    /// Commits a move through the workspace aggregate and then publishes its
    /// canonical position. Failed commands have no observable effects.
    ///
    /// ```zig
    /// const moved = try handler.execute(.{ .location = location, .direction = .previous });
    /// ```
    pub fn execute(handler: *MoveTabHandler, command: MoveTab) !MoveTabResult {
        const moved = try workspace_mod.moveTab(
            handler.workspaces,
            command.location,
            command.direction,
        );

        handler.events.publish(handler.events.context, moved);
        return moved;
    }

    /// Exposes this handler through the command interface consumed by a
    /// request-scoped controller.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *MoveTabHandler) MoveTabExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: MoveTab) !MoveTabResult {
        const handler: *MoveTabHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const EventCapture = struct {
    reader: workspace_mod.Reader,
    count: usize = 0,
    last: ?workspace_mod.TabMoved = null,
    observed_committed_position: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabMoved) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        var storage: [workspace_mod.max_tabs_per_workspace]schema.TabDescriptor = undefined;
        const snapshot = capture.reader.descriptors(event.location.workspace, &storage) orelse return;

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_position = snapshot.tabs[event.position].tab_id == event.location.tab_id;
    }
};

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

fn appendTestingTab(workspaces: *WorkspaceRepository, workspace: schema.WorkspaceLocation) !schema.TabLocation {
    const aggregate = workspaces.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try workspaces.nextTabId();
    const created = try aggregate.createTab(tab_id, "logs");
    workspaces.recordTabCreated(tab_id);
    return created.location;
}

test "MoveTabHandler commits before publishing the canonical position" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const moved_location = try appendTestingTab(&workspaces, initial.workspace);
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: MoveTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    const moved = try handler.execute(.{
        .location = moved_location,
        .direction = .previous,
    });

    try std.testing.expectEqualDeep(moved_location, moved.location);
    try std.testing.expectEqual(@as(u16, 0), moved.position);
    try std.testing.expectEqual(moved_location.tab_id, workspaces.reader().defaultTab(initial.workspace).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.observed_committed_position);
    try std.testing.expectEqualDeep(moved, capture.last.?);
}

test "MoveTabHandler publishes a successful move at either edge" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: MoveTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    const previous = try handler.execute(.{ .location = location, .direction = .previous });
    const next = try handler.execute(.{ .location = location, .direction = .next });

    try std.testing.expectEqual(@as(u16, 0), previous.position);
    try std.testing.expectEqual(@as(u16, 0), next.position);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.observed_committed_position);
}

test "MoveTabHandler rejects missing workspaces and tabs without publishing" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: MoveTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    var missing_tab = location;
    missing_tab.tab_id = try schema.id.tab(999);
    const missing_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(999) },
        .tab_id = location.tab_id,
    };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .direction = .next,
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = missing_workspace,
        .direction = .previous,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
