//! Application command for moving a tab inside its workspace aggregate.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;
pub const WorkspaceRepository = workspace_mod.Repository;

pub const MoveTab = @import("MoveTab.zig");

pub const MoveTabResult = workspace_mod.TabMoved;

pub const EventPublisher = @import("MoveTabEventPublisher.zig");

pub const MoveTabExecutor = @import("MoveTabExecutor.zig");

pub const MoveTabHandler = @import("MoveTabHandler.zig");

const EventCapture = @import("MoveTabEventCapture.zig");

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
