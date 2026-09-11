//! Vertical contract tests for the runtime tab rename flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const RenameTabTestEventCapture = @import("RenameTabTestEventCapture.zig");
const RenameTabHandlerType = @import("../application/commands/RenameTabHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const RenameTabController = @import("../entrypoints/requests/RenameTabController.zig");

test "a committed rename survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var events: RenameTabTestEventCapture = .{};
    var handler: RenameTabHandlerType = .{
        .workspaces = &workspaces,
        .events = events.publisher(),
    };
    var responses: ResponseQueueType = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var controller = RenameTabController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.renameTab(.{
        .request_id = @enumFromInt(31),
        .location = location,
        .label = "server",
    }));

    try std.testing.expectEqualStrings("server", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(location, events.last.?.location);
    try std.testing.expectEqualStrings("server", events.last.?.labelSlice());
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
