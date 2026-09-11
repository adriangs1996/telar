//! Request-scoped controller for the rename-tab protocol message.

const std = @import("std");
const core = @import("telar-core");
const rename_tab_commands = @import("../../application/commands/rename_tab.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const PendingTabRenamed = delivery_mod.PendingTabRenamed;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("RenameTabController.zig");

const Failure = @import("RenameTabFailure.zig");

const StubRenameTab = @import("StubRenameTab.zig");

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "Controller maps a rename request and queues the canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try schema.id.tab(8);
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameTab = .{
        .result = try rename_tab_commands.RenameTabResult.init(canonical_location, "canonical"),
    };
    var controller = Controller.init(&responses, rename_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

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
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.TabNotFound, .failure_code = .tab_not_found, .message = "tab not found" },
        .{ .command_error = error.InvalidTabLabel, .failure_code = .invalid_request, .message = "invalid tab label" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var rename_stub: StubRenameTab = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, rename_stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

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
    var controller = Controller.init(&responses, rename_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.renameTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
        .label = "requested",
    }));

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
