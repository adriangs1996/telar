//! Request-scoped controller for the close-pane protocol message.

const std = @import("std");
const core = @import("telar-core");
const close_pane_commands = @import("../../application/commands/close_pane.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("ClosePaneController.zig");

const StubClosePane = @import("StubClosePane.zig");

test "Controller requests pane closure without inventing an acknowledgement" {
    const pane_id = try schema.id.pane(7);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{ .result = .{
        .pane_id = pane_id,
        .newly_requested = true,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try controller.closePane(.{
        .request_id = @enumFromInt(11),
        .pane_id = pane_id,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.last_command.?.pane_id);
    try std.testing.expect(responses.peek() == null);
}

test "Controller maps a detached pane to one protocol failure" {
    const pane_id = try schema.id.pane(7);
    const request_id: schema.RequestId = @enumFromInt(20);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{
        .result = .{ .pane_id = pane_id, .newly_requested = false },
        .failure = error.PaneNotAttached,
    };
    var controller = Controller.init(&responses, stub.executor());

    try controller.closePane(.{ .request_id = request_id, .pane_id = pane_id });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("pane not attached", response.request_failed.message);
}

test "Controller propagates unexpected pane close failures" {
    const pane_id = try schema.id.pane(7);
    var responses: ResponseQueue = .{};
    var stub: StubClosePane = .{
        .result = .{ .pane_id = pane_id, .newly_requested = false },
        .failure = error.PaneCloserUnavailable,
    };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.PaneCloserUnavailable, controller.closePane(.{
        .request_id = @enumFromInt(30),
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports backpressure while mapping a detached pane" {
    const pane_id = try schema.id.pane(7);
    const filler_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(4),
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
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.closePane(.{
        .request_id = @enumFromInt(31),
        .pane_id = pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
