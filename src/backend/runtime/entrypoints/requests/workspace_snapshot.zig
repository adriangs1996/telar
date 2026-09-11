//! Request-scoped controller for workspace-snapshot protocol messages.

const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const workspace_module = @import("telar-core").workspace;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const WorkspaceSnapshotStubQuery = @import("WorkspaceSnapshotStubQuery.zig");
const WorkspaceSnapshotController = @import("WorkspaceSnapshotController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;
const TabLocationType = @import("telar-core").TabLocation;
const tab_module = @import("telar-core").tab;

fn testingLocation() !WorkspaceLocationType {
    return .{ .workspace = try workspace_module(3) };
}

test "Controller maps a workspace snapshot request to its canonical result" {
    const requested_location = try testingLocation();
    const canonical_location: WorkspaceLocationType = .{ .workspace = try workspace_module(4) };
    var responses: ResponseQueue = .{};
    var query_stub: WorkspaceSnapshotStubQuery = .{ .result = .{ .location = canonical_location } };
    var controller = WorkspaceSnapshotController.init(&responses, query_stub.executor());
    const request_id: RequestIdType = @enumFromInt(11);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = requested_location,
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, query_stub.last_request.?.location);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.workspace_snapshot.workspace);
}

test "Controller maps a missing workspace to one protocol failure" {
    var responses: ResponseQueue = .{};
    var query_stub: WorkspaceSnapshotStubQuery = .{ .failure = error.WorkspaceNotFound };
    var controller = WorkspaceSnapshotController.init(&responses, query_stub.executor());
    const request_id: RequestIdType = @enumFromInt(20);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = try testingLocation(),
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(FailureCodeType.workspace_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("workspace not found", response.request_failed.message);
}

test "Controller propagates unexpected workspace query failures" {
    var responses: ResponseQueue = .{};
    var query_stub: WorkspaceSnapshotStubQuery = .{ .failure = error.QuerySourceUnavailable };
    var controller = WorkspaceSnapshotController.init(&responses, query_stub.executor());

    try std.testing.expectError(error.QuerySourceUnavailable, controller.requestWorkspaceSnapshot(.{
        .request_id = @enumFromInt(30),
        .workspace = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports response backpressure after a successful workspace query" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};
    const tab_location: TabLocationType = .{
        .workspace = location,
        .tab_id = try tab_module(1),
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = tab_location,
            .position = 0,
        } });
    }

    var query_stub: WorkspaceSnapshotStubQuery = .{ .result = .{ .location = location } };
    var controller = WorkspaceSnapshotController.init(&responses, query_stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.requestWorkspaceSnapshot(.{
        .request_id = @enumFromInt(31),
        .workspace = location,
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
