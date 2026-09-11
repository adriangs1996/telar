//! Application transaction for removing a tab and closing its panes.

const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const CloseTabPaneCapture = @import("CloseTabPaneCapture.zig");
const CloseTabEventCapture = @import("CloseTabEventCapture.zig");
const CloseTabHandler = @import("CloseTabHandler.zig");
const tab_module = @import("telar-core").tab;
const workspace_module = @import("telar-core").workspace;

fn testingRepository(state: *StateType) RepositoryType {
    return RepositoryType.init(state, std.testing.allocator);
}

fn insertTestingTab(repository: *RepositoryType, workspace: WorkspaceLocationType, label: []const u8) !TabLocationType {
    const aggregate = repository.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try repository.nextTabId();
    const created = try aggregate.createTab(tab_id, label);
    repository.recordTabCreated(tab_id);
    return created.location;
}

test "CloseTabHandler commits a tab-only removal before its effects" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const logs = try insertTestingTab(&workspaces, initial.workspace, "logs");
    const revision = workspaces.reader().revision();
    var panes: CloseTabPaneCapture = .{};
    var events: CloseTabEventCapture = .{
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
    var state: StateType = .{};
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
    var panes: CloseTabPaneCapture = .{};
    var events: CloseTabEventCapture = .{
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const existing = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var panes: CloseTabPaneCapture = .{};
    var events: CloseTabEventCapture = .{
        .reader = workspaces.reader(),
        .pane_close_count = &panes.close_count,
    };
    var handler: CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };
    const missing_tab: TabLocationType = .{
        .workspace = existing.workspace,
        .tab_id = try tab_module(999),
    };
    const missing_workspace: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(999) },
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var panes: CloseTabPaneCapture = .{};
    var events: CloseTabEventCapture = .{
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
