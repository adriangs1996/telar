//! Completion policy for one asynchronous runtime-to-client send.

const GenericRuntimePort = @import("GenericRuntimePort.zig").Type;
const SendCoordinatorCapture = @import("SendCoordinatorCapture.zig");
const TestTypes = @import("TestTypes.zig");
const GenericCoordinator = @import("GenericCoordinator.zig").Type;
const std = @import("std");

pub const Step = enum {
    resolve,
    record_stale,
    release_send,
    is_closing,
    finalize,
    complete_delivery,
    drop_client,
    detach_after_send,
    should_close_after_reply,
    stopping,
    pump_client,
    pump_all,
    shutdown_delivered,
};

const test_port: GenericRuntimePort(SendCoordinatorCapture, TestTypes) = .{
    .resolve = SendCoordinatorCapture.resolve,
    .record_stale = SendCoordinatorCapture.recordStale,
    .release_send = SendCoordinatorCapture.releaseSend,
    .is_closing = SendCoordinatorCapture.isClosing,
    .finalize = SendCoordinatorCapture.finalize,
    .complete_delivery = SendCoordinatorCapture.completeDelivery,
    .drop_client = SendCoordinatorCapture.dropClient,
    .detach_after_send = SendCoordinatorCapture.detachAfterSend,
    .should_close_after_reply = SendCoordinatorCapture.shouldCloseAfterReply,
    .stopping = SendCoordinatorCapture.stopping,
    .pump_client = SendCoordinatorCapture.pumpClient,
    .pump_all = SendCoordinatorCapture.pumpAll,
    .shutdown_delivered = SendCoordinatorCapture.shutdownDelivered,
};

const TestCoordinator = GenericCoordinator(SendCoordinatorCapture, TestTypes, test_port);

fn expectSteps(capture: *const SendCoordinatorCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a stale completion records one stale message without touching a session" {
    var capture: SendCoordinatorCapture = .{ .resolve_client = false };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{ .resolve, .record_stale });
    try std.testing.expect(capture.session.send_pending);
}

test "a closing session releases the send before finalization" {
    var capture: SendCoordinatorCapture = .{ .session = .{ .closing = true }, .shutdown_complete = true };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{ .resolve, .release_send, .is_closing, .finalize, .shutdown_delivered });
    try std.testing.expect(!capture.session.send_pending);
    try std.testing.expectEqual(@as(?u8, 7), capture.finalized_client);
}

test "a failed delivery closes the client before deferred effects" {
    var capture: SendCoordinatorCapture = .{ .completion = .{ .close_client = true, .detach_pane = 9 } };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = error.SendFailed }));

    try expectSteps(&capture, &.{ .resolve, .release_send, .is_closing, .complete_delivery, .drop_client, .shutdown_delivered });
    try std.testing.expect(capture.completion_saw_failure);
    try std.testing.expectEqual(@as(?u8, 7), capture.dropped_client);
    try std.testing.expectEqual(@as(?u8, null), capture.detached_pane);
}

test "a successful deferred detach precedes the next delivery pump" {
    var capture: SendCoordinatorCapture = .{ .completion = .{ .detach_pane = 9 } };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{
        .resolve,
        .release_send,
        .is_closing,
        .complete_delivery,
        .detach_after_send,
        .should_close_after_reply,
        .pump_client,
        .stopping,
    });
    try std.testing.expectEqual(@as(?u8, 9), capture.detached_pane);
}

test "close-after-reply drops an active client without retrying delivery" {
    var capture: SendCoordinatorCapture = .{ .session = .{ .close_after_reply = true } };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{
        .resolve,
        .release_send,
        .is_closing,
        .complete_delivery,
        .should_close_after_reply,
        .stopping,
        .drop_client,
    });
    try std.testing.expectEqual(@as(?u8, 7), capture.dropped_client);
}

test "shutdown defers close-after-reply until the stopping delivery completes" {
    var capture: SendCoordinatorCapture = .{
        .session = .{ .close_after_reply = true },
        .runtime_stopping = true,
        .shutdown_complete = true,
    };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{
        .resolve,
        .release_send,
        .is_closing,
        .complete_delivery,
        .should_close_after_reply,
        .stopping,
        .pump_client,
        .stopping,
        .pump_all,
        .shutdown_delivered,
    });
    try std.testing.expectEqual(@as(?u8, null), capture.dropped_client);
}

test "delivery retry failure drops the client" {
    var capture: SendCoordinatorCapture = .{ .pump_failure = true };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{
        .resolve,
        .release_send,
        .is_closing,
        .complete_delivery,
        .should_close_after_reply,
        .pump_client,
        .drop_client,
        .stopping,
    });
    try std.testing.expectEqual(@as(?u8, 7), capture.dropped_client);
}

test "an active shutdown pumps every client before checking completion" {
    var capture: SendCoordinatorCapture = .{ .runtime_stopping = true, .shutdown_complete = true };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{
        .resolve,
        .release_send,
        .is_closing,
        .complete_delivery,
        .should_close_after_reply,
        .pump_client,
        .stopping,
        .pump_all,
        .shutdown_delivered,
    });
}
