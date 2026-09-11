//! Request-scoped controller for the rename-tab protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubRenameTab = @import("StubRenameTab.zig");
const TabRenamed = @import("../../../workspace/TabRenamed.zig");
const RenameTabController = @import("RenameTabController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

test "Controller maps a rename request and queues the canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try tab_module(8);
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameTab = .{
        .result = try TabRenamed.init(canonical_location, "canonical"),
    };
    var controller = RenameTabController.init(&responses, rename_stub.executor());
    const request_id: RequestIdType = @enumFromInt(11);

    try controller.renameTab(.{
        .request_id = request_id,
        .location = requested_location,
        .label = "requested",
    });

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, rename_stub.last_location.?);
    try std.testing.expectEqualStrings("requested", rename_stub.lastLabel());
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_renamed);
    try std.testing.expectEqual(request_id, response.tab_renamed.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_renamed.location);
    try std.testing.expectEqualStrings("canonical", response.tab_renamed.labelSlice());
}

test "Controller maps rename command errors without inventing domain effects" {
    const location = try testingLocation();
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.TabNotFound, .failure_code = .tab_not_found, .message = "tab not found" },
        .{ .command_error = error.InvalidTabLabel, .failure_code = .invalid_request, .message = "invalid tab label" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var rename_stub: StubRenameTab = .{ .failure = case.command_error };
        var controller = RenameTabController.init(&responses, rename_stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

        try controller.renameTab(.{
            .request_id = request_id,
            .location = location,
            .label = "requested",
        });

        try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected command failures without a response" {
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = RenameTabController.init(&responses, rename_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.renameTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
        .label = "requested",
    }));

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
