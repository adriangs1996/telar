//! Completion policy for one asynchronous runtime-to-client send.

const std = @import("std");

pub const SentEvent = @import("GenericSentEvent.zig").Type;

pub const RuntimePort = @import("GenericRuntimePort.zig").Type;

pub const Coordinator = @import("GenericCoordinator.zig").Type;

const FakeSession = @import("SendCoordinatorFakeSession.zig");

const FakeCompletion = @import("FakeCompletion.zig");

const TestTypes = @import("TestTypes.zig");

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

const Capture = @import("SendCoordinatorCapture.zig");

const test_port: RuntimePort(Capture, TestTypes) = .{
    .resolve = Capture.resolve,
    .record_stale = Capture.recordStale,
    .release_send = Capture.releaseSend,
    .is_closing = Capture.isClosing,
    .finalize = Capture.finalize,
    .complete_delivery = Capture.completeDelivery,
    .drop_client = Capture.dropClient,
    .detach_after_send = Capture.detachAfterSend,
    .should_close_after_reply = Capture.shouldCloseAfterReply,
    .stopping = Capture.stopping,
    .pump_client = Capture.pumpClient,
    .pump_all = Capture.pumpAll,
    .shutdown_delivered = Capture.shutdownDelivered,
};

const TestCoordinator = Coordinator(Capture, TestTypes, test_port);

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a stale completion records one stale message without touching a session" {
    var capture: Capture = .{ .resolve_client = false };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{ .resolve, .record_stale });
    try std.testing.expect(capture.session.send_pending);
}

test "a closing session releases the send before finalization" {
    var capture: Capture = .{ .session = .{ .closing = true }, .shutdown_complete = true };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(coordinator.handle(.{ .client = 7, .result = {} }));

    try expectSteps(&capture, &.{ .resolve, .release_send, .is_closing, .finalize, .shutdown_delivered });
    try std.testing.expect(!capture.session.send_pending);
    try std.testing.expectEqual(@as(?u8, 7), capture.finalized_client);
}

test "a failed delivery closes the client before deferred effects" {
    var capture: Capture = .{ .completion = .{ .close_client = true, .detach_pane = 9 } };
    var coordinator = TestCoordinator.init(&capture);

    try std.testing.expect(!coordinator.handle(.{ .client = 7, .result = error.SendFailed }));

    try expectSteps(&capture, &.{ .resolve, .release_send, .is_closing, .complete_delivery, .drop_client, .shutdown_delivered });
    try std.testing.expect(capture.completion_saw_failure);
    try std.testing.expectEqual(@as(?u8, 7), capture.dropped_client);
    try std.testing.expectEqual(@as(?u8, null), capture.detached_pane);
}

test "a successful deferred detach precedes the next delivery pump" {
    var capture: Capture = .{ .completion = .{ .detach_pane = 9 } };
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
    var capture: Capture = .{ .session = .{ .close_after_reply = true } };
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
    var capture: Capture = .{
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
    var capture: Capture = .{ .pump_failure = true };
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
    var capture: Capture = .{ .runtime_stopping = true, .shutdown_complete = true };
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
