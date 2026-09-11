//! Vertical contract tests for the runtime workspace rename flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const RenameWorkspaceTestEventCapture = @import("RenameWorkspaceTestEventCapture.zig");
const RenameWorkspaceHandlerType = @import("../application/commands/RenameWorkspaceHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const TabLocationType = @import("telar-core").TabLocation;
const RenameWorkspaceController = @import("../entrypoints/requests/RenameWorkspaceController.zig");

test "a committed workspace rename survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var events: RenameWorkspaceTestEventCapture = .{};
    var handler: RenameWorkspaceHandlerType = .{
        .workspaces = &workspaces,
        .events = events.publisher(),
    };
    var responses: ResponseQueueType = .{};
    const tab_location: TabLocationType = .{
        .workspace = location,
        .tab_id = workspaces.reader().defaultTab(location).?,
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = tab_location,
            .position = 0,
        } });
    }

    var requested_name = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    var controller = RenameWorkspaceController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.renameWorkspace(.{
        .request_id = @enumFromInt(31),
        .workspace = location,
        .name = &requested_name,
    }));
    @memset(&requested_name, 'x');

    try std.testing.expectEqualStrings("backend", workspaces.reader().workspaceName(location).?);
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(location, events.last.?.location);
    try std.testing.expectEqualStrings("backend", events.last.?.nameSlice());
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
