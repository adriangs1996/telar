//! Request-scoped controller for the close-tab protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const TabRemovedType = @import("../../../workspace/TabRemoved.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubCloseTab = @import("StubCloseTab.zig");
const CloseTabController = @import("CloseTabController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation(workspace_id: u64, tab_id: u64) !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(workspace_id) },
        .tab_id = try tab_module(tab_id),
    };
}

test "Controller maps tab-only and whole-workspace removal results" {
    const requested = try testingLocation(3, 7);
    const canonical = try testingLocation(3, 8);
    const previous = try workspace_module(2);
    const cases = [_]struct {
        result: TabRemovedType,
        workspace_closed: bool,
        previous_workspace: ?WorkspaceIdType,
    }{
        .{
            .result = try TabRemovedType.init(canonical, false, null),
            .workspace_closed = false,
            .previous_workspace = null,
        },
        .{
            .result = try TabRemovedType.init(canonical, true, previous),
            .workspace_closed = true,
            .previous_workspace = previous,
        },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCloseTab = .{ .result = case.result };
        var controller = CloseTabController.init(&responses, stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 11);

        try controller.closeTab(.{
            .request_id = request_id,
            .location = requested,
        });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqualDeep(requested, stub.last_location.?);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .tab_closed);
        try std.testing.expectEqual(request_id, response.tab_closed.request_id);
        try std.testing.expectEqualDeep(canonical, response.tab_closed.location);
        try std.testing.expectEqual(case.workspace_closed, response.tab_closed.workspace_closed);
        try std.testing.expectEqual(case.previous_workspace, response.tab_closed.previous_workspace);
    }
}

test "Controller maps a missing tab without inventing a success" {
    const location = try testingLocation(3, 7);
    const request_id: RequestIdType = @enumFromInt(20);
    var responses: ResponseQueue = .{};
    var stub: StubCloseTab = .{ .failure = error.TabNotFound };
    var controller = CloseTabController.init(&responses, stub.executor());

    try controller.closeTab(.{
        .request_id = request_id,
        .location = location,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(FailureCodeType.tab_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("tab not found", response.request_failed.message);
}

test "Controller propagates unexpected close-tab failures without a response" {
    var responses: ResponseQueue = .{};
    var stub: StubCloseTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = CloseTabController.init(&responses, stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.closeTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(3, 7),
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
