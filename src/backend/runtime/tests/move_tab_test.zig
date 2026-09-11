//! Vertical contract tests for the runtime move-tab flow.

const RepositoryType = @import("../../workspace/Repository.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const StateType = @import("../../workspace/State.zig");
const std = @import("std");
const MoveTabTestEventCapture = @import("MoveTabTestEventCapture.zig");
const MoveTabHandlerType = @import("../application/commands/MoveTabHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const MoveTabController = @import("../entrypoints/requests/MoveTabController.zig");

fn appendTestingTab(workspaces: *RepositoryType, workspace: WorkspaceLocationType) !TabLocationType {
    const aggregate = workspaces.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try workspaces.nextTabId();
    const created = try aggregate.createTab(tab_id, "logs");
    workspaces.recordTabCreated(tab_id);
    return created.location;
}

test "a committed tab move survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const moved_location = try appendTestingTab(&workspaces, initial.workspace);
    const revision = workspaces.reader().revision();
    var events: MoveTabTestEventCapture = .{};
    var handler: MoveTabHandlerType = .{
        .workspaces = &workspaces,
        .events = events.publisher(),
    };
    var responses: ResponseQueueType = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = initial,
            .position = 0,
        } });
    }

    var controller = MoveTabController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.moveTab(.{
        .request_id = @enumFromInt(31),
        .location = moved_location,
        .direction = .previous,
    }));

    try std.testing.expectEqual(moved_location.tab_id, workspaces.reader().defaultTab(initial.workspace).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(moved_location, events.last.?.location);
    try std.testing.expectEqual(@as(u16, 0), events.last.?.position);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
