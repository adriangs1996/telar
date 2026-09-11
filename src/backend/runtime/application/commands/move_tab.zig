//! Application command for moving a tab inside its workspace aggregate.

const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const MoveTabEventCapture = @import("MoveTabEventCapture.zig");
const MoveTabHandler = @import("MoveTabHandler.zig");
const tab_module = @import("telar-core").tab;
const workspace_module = @import("telar-core").workspace;

fn testingRepository(state: *StateType) RepositoryType {
    return RepositoryType.init(state, std.testing.allocator);
}

fn appendTestingTab(workspaces: *RepositoryType, workspace: WorkspaceLocationType) !TabLocationType {
    const aggregate = workspaces.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try workspaces.nextTabId();
    const created = try aggregate.createTab(tab_id, "logs");
    workspaces.recordTabCreated(tab_id);
    return created.location;
}

test "MoveTabHandler commits before publishing the canonical position" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const moved_location = try appendTestingTab(&workspaces, initial.workspace);
    const revision = workspaces.reader().revision();
    var capture: MoveTabEventCapture = .{ .reader = workspaces.reader() };
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var capture: MoveTabEventCapture = .{ .reader = workspaces.reader() };
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
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var capture: MoveTabEventCapture = .{ .reader = workspaces.reader() };
    var handler: MoveTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    var missing_tab = location;
    missing_tab.tab_id = try tab_module(999);
    const missing_workspace: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(999) },
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
