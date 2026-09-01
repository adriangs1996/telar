//! Application transaction for removing a tab and closing its panes.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const CloseTab = struct {
    location: schema.TabLocation,
};

pub const CloseTabResult = workspace_mod.TabRemoved;

/// Infallible runtime effect that starts closing every pane owned by a tab.
pub const PaneCloser = struct {
    context: *anyopaque,
    close_all: *const fn (*anyopaque, schema.TabLocation) void,
};

/// Synchronous post-commit port. Implementations may retain the event value.
pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.TabRemoved) void,
};

pub const CloseTabExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CloseTab) anyerror!CloseTabResult,

    /// Executes tab closure through the bound application handler.
    ///
    /// ```zig
    /// const removed = try executor.execute(.{ .location = location });
    /// ```
    pub fn execute(executor: CloseTabExecutor, command: CloseTab) !CloseTabResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const CloseTabHandler = struct {
    workspaces: *WorkspaceRepository,
    panes: PaneCloser,
    events: EventPublisher,

    /// Commits one tab removal, starts closing its runtime panes, then
    /// publishes the resulting domain fact. A missing tab has no effects.
    /// Pane closure and event publication are infallible post-commit ports.
    ///
    /// ```zig
    /// const removed = try handler.execute(.{ .location = location });
    /// ```
    pub fn execute(handler: *CloseTabHandler, command: CloseTab) !CloseTabResult {
        const removed = workspace_mod.removeTab(handler.workspaces, command.location) orelse return error.TabNotFound;

        handler.panes.close_all(handler.panes.context, removed.location);
        handler.events.publish(handler.events.context, removed);
        return removed;
    }

    /// Erases the concrete handler behind the command interface consumed by
    /// request controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *CloseTabHandler) CloseTabExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: CloseTab) !CloseTabResult {
        const handler: *CloseTabHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const PaneCapture = struct {
    close_count: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn port(capture: *PaneCapture) PaneCloser {
        return .{ .context = capture, .close_all = closeAll };
    }

    fn closeAll(context: *anyopaque, location: schema.TabLocation) void {
        const capture: *PaneCapture = @ptrCast(@alignCast(context));
        capture.close_count += 1;
        capture.last_location = location;
    }
};

const EventCapture = struct {
    reader: workspace_mod.Reader,
    pane_close_count: *const usize,
    count: usize = 0,
    last: ?workspace_mod.TabRemoved = null,
    observed_committed_state: bool = false,
    observed_closed_panes: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabRemoved) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        const workspace_exists = capture.reader.containsWorkspace(event.location.workspace);

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_state = !capture.reader.contains(event.location) and
            (if (event.workspace_removed) !workspace_exists else workspace_exists);
        capture.observed_closed_panes = capture.pane_close_count.* == 1;
    }
};

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

fn insertTestingTab(repository: *WorkspaceRepository, workspace: schema.WorkspaceLocation, label: []const u8) !schema.TabLocation {
    const aggregate = repository.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try repository.nextTabId();
    const created = try aggregate.createTab(tab_id, label);
    repository.recordTabCreated(tab_id);
    return created.location;
}

test "CloseTabHandler commits a tab-only removal before its effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const logs = try insertTestingTab(&workspaces, initial.workspace, "logs");
    const revision = workspaces.reader().revision();
    var panes: PaneCapture = .{};
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .pane_close_count = &panes.close_count,
    };
    var handler: CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };

    const removed = try handler.executor().execute(.{ .location = logs });

    try std.testing.expectEqualDeep(logs, removed.location);
    try std.testing.expect(!removed.workspace_removed);
    try std.testing.expect(removed.previous_workspace == null);
    try std.testing.expect(workspaces.reader().contains(initial));
    try std.testing.expect(!workspaces.reader().contains(logs));
    try std.testing.expectEqual(revision + 1, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), panes.close_count);
    try std.testing.expectEqualDeep(logs, panes.last_location.?);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expect(events.observed_committed_state);
    try std.testing.expect(events.observed_closed_panes);
    try std.testing.expectEqualDeep(removed, events.last.?);
}

test "CloseTabHandler removes an empty workspace with its stable predecessor" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const first = (try workspaces.ensure("/work/first")).location;
    const second = (try workspaces.ensure("/work/second")).location;
    _ = try workspaces.ensure("/work/third");
    const first_workspace = switch (first.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => unreachable,
    };
    const revision = workspaces.reader().revision();
    var panes: PaneCapture = .{};
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .pane_close_count = &panes.close_count,
    };
    var handler: CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };

    const removed = try handler.execute(.{ .location = second });

    try std.testing.expect(removed.workspace_removed);
    try std.testing.expectEqual(first_workspace, removed.previous_workspace.?);
    try std.testing.expect(!workspaces.reader().containsWorkspace(second.workspace));
    try std.testing.expectEqual(@as(usize, 2), workspaces.reader().count());
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), panes.close_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expect(events.observed_committed_state);
    try std.testing.expect(events.observed_closed_panes);
}

test "CloseTabHandler rejects missing targets without effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const existing = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var panes: PaneCapture = .{};
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .pane_close_count = &panes.close_count,
    };
    var handler: CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };
    const missing_tab: schema.TabLocation = .{
        .workspace = existing.workspace,
        .tab_id = try schema.id.tab(999),
    };
    const missing_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(999) },
        .tab_id = existing.tab_id,
    };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{ .location = missing_tab }));
    try std.testing.expectError(error.TabNotFound, handler.execute(.{ .location = missing_workspace }));

    try std.testing.expect(workspaces.reader().contains(existing));
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), panes.close_count);
    try std.testing.expectEqual(@as(usize, 0), events.count);
}

test "CloseTabHandler does not repeat effects for an already removed tab" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: PaneCapture = .{};
    var events: EventCapture = .{
        .reader = workspaces.reader(),
        .pane_close_count = &panes.close_count,
    };
    var handler: CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };

    _ = try handler.execute(.{ .location = location });
    try std.testing.expectError(error.TabNotFound, handler.execute(.{ .location = location }));

    try std.testing.expectEqual(@as(usize, 1), panes.close_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
}
