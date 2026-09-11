//! Vertical contract tests for the runtime tab-snapshot flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const SourceContext = @import("SourceContext.zig");
const TabSnapshotHandler = @import("../application/queries/TabSnapshotHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const TabSnapshotController = @import("../entrypoints/requests/TabSnapshotController.zig");
const RequestIdType = @import("telar-core").RequestId;

test "a live aggregate tab crosses query and controller boundaries" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var source_context: SourceContext = .{
        .workspaces = &workspaces,
        .live_location = location,
    };
    var handler: TabSnapshotHandler = .{ .source = source_context.source() };
    var responses: ResponseQueueType = .{};
    var controller = TabSnapshotController.init(&responses, handler.executor());
    const request_id: RequestIdType = @enumFromInt(41);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = location,
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_snapshot);
    try std.testing.expectEqual(request_id, response.tab_snapshot.request_id);
    try std.testing.expectEqualDeep(location, response.tab_snapshot.location);
}
