//! Request-scoped controller for tab-snapshot protocol messages.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const TabSnapshotStubQuery = @import("TabSnapshotStubQuery.zig");
const TabSnapshotController = @import("TabSnapshotController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

test "Controller maps a tab snapshot request to its canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try tab_module(8);
    var responses: ResponseQueue = .{};
    var query_stub: TabSnapshotStubQuery = .{
        .result = .{ .location = canonical_location },
    };
    var controller = TabSnapshotController.init(&responses, query_stub.executor());
    const request_id: RequestIdType = @enumFromInt(11);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = requested_location,
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, query_stub.last_request.?.location);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_snapshot);
    try std.testing.expectEqual(request_id, response.tab_snapshot.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_snapshot.location);
}

test "Controller maps a missing tab to one protocol failure" {
    var responses: ResponseQueue = .{};
    var query_stub: TabSnapshotStubQuery = .{ .failure = error.TabNotFound };
    var controller = TabSnapshotController.init(&responses, query_stub.executor());
    const request_id: RequestIdType = @enumFromInt(20);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = try testingLocation(),
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(FailureCodeType.tab_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("tab not found", response.request_failed.message);
}

test "Controller propagates unexpected query failures without a response" {
    var responses: ResponseQueue = .{};
    var query_stub: TabSnapshotStubQuery = .{ .failure = error.QuerySourceUnavailable };
    var controller = TabSnapshotController.init(&responses, query_stub.executor());

    try std.testing.expectError(error.QuerySourceUnavailable, controller.requestTabSnapshot(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports response backpressure after a successful query" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var query_stub: TabSnapshotStubQuery = .{ .result = .{ .location = location } };
    var controller = TabSnapshotController.init(&responses, query_stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.requestTabSnapshot(.{
        .request_id = @enumFromInt(31),
        .location = location,
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
