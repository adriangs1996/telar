//! Request-scoped controller for the move-tab protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubMoveTab = @import("StubMoveTab.zig");
const MoveTabController = @import("MoveTabController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const TabMoveDirectionType = @import("telar-core").TabMoveDirection;
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

test "Controller maps a move request and queues the canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try tab_module(8);
    var responses: ResponseQueue = .{};
    var move_stub: StubMoveTab = .{
        .result = .{ .location = canonical_location, .position = 2 },
    };
    var controller = MoveTabController.init(&responses, move_stub.executor());
    const request_id: RequestIdType = @enumFromInt(11);

    try controller.moveTab(.{
        .request_id = request_id,
        .location = requested_location,
        .direction = .next,
    });

    try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, move_stub.last_command.?.location);
    try std.testing.expectEqual(TabMoveDirectionType.next, move_stub.last_command.?.direction);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_moved);
    try std.testing.expectEqual(request_id, response.tab_moved.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_moved.location);
    try std.testing.expectEqual(@as(u16, 2), response.tab_moved.position);
}

test "Controller maps expected move errors without a success response" {
    const location = try testingLocation();
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.TabNotFound, .failure_code = .tab_not_found, .message = "tab not found" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var move_stub: StubMoveTab = .{ .failure = case.command_error };
        var controller = MoveTabController.init(&responses, move_stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

        try controller.moveTab(.{
            .request_id = request_id,
            .location = location,
            .direction = .previous,
        });

        try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected move failures without a response" {
    var responses: ResponseQueue = .{};
    var move_stub: StubMoveTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = MoveTabController.init(&responses, move_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.moveTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
        .direction = .next,
    }));

    try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
