//! Request-scoped controller for the close-pane protocol message.

const pane_module = @import("telar-core").pane;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubClosePane = @import("StubClosePane.zig");
const ClosePaneController = @import("ClosePaneController.zig");
const std = @import("std");
const RequestIdType = @import("telar-core").RequestId;
const FailureCodeType = @import("telar-core").FailureCode;
const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;

test "Controller requests pane closure without inventing an acknowledgement" {
    const pane_id = try pane_module(7);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{ .result = .{
        .pane_id = pane_id,
        .newly_requested = true,
    } };
    var controller = ClosePaneController.init(&responses, stub.executor());

    try controller.closePane(.{
        .request_id = @enumFromInt(11),
        .pane_id = pane_id,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.last_command.?.pane_id);
    try std.testing.expect(responses.peek() == null);
}

test "Controller maps a detached pane to one protocol failure" {
    const pane_id = try pane_module(7);
    const request_id: RequestIdType = @enumFromInt(20);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{
        .result = .{ .pane_id = pane_id, .newly_requested = false },
        .failure = error.PaneNotAttached,
    };
    var controller = ClosePaneController.init(&responses, stub.executor());

    try controller.closePane(.{ .request_id = request_id, .pane_id = pane_id });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(FailureCodeType.pane_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("pane not attached", response.request_failed.message);
}

test "Controller propagates unexpected pane close failures" {
    const pane_id = try pane_module(7);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{
        .result = .{ .pane_id = pane_id, .newly_requested = false },
        .failure = error.PaneCloserUnavailable,
    };
    var controller = ClosePaneController.init(&responses, stub.executor());

    try std.testing.expectError(error.PaneCloserUnavailable, controller.closePane(.{
        .request_id = @enumFromInt(30),
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports backpressure while mapping a detached pane" {
    const pane_id = try pane_module(7);
    const filler_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(4),
    };
    var responses: ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = filler_location,
            .position = 0,
        } });
    }

    var stub: StubClosePane = .{
        .result = .{ .pane_id = pane_id, .newly_requested = false },
        .failure = error.PaneNotAttached,
    };
    var controller = ClosePaneController.init(&responses, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.closePane(.{
        .request_id = @enumFromInt(31),
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
