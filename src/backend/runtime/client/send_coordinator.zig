//! Completion policy for one asynchronous runtime-to-client send.

const std = @import("std");

/// Creates the owned event delivered when one client send actor completes.
/// `Types` declares the client identity type.
///
/// ```zig
/// const Event = SentEvent(Types);
/// const event: Event = .{ .client = client, .result = {} };
/// ```
pub fn SentEvent(comptime Types: type) type {
    return struct {
        client: Types.Client,
        result: anyerror!void,
    };
}

/// Defines client lookup, delivery mutation, lifecycle effects, and shutdown
/// queries supplied by the runtime composition root. `Types` declares
/// `Client`, `Session`, `Completion`, and `Detach`; a completion exposes
/// `close_client` and `detach_pane` fields.
///
/// ```zig
/// const port: RuntimePort(Context, Types) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type, comptime Types: type) type {
    return struct {
        resolve: *const fn (*Context, Types.Client) ?Types.Session,
        record_stale: *const fn (*Context) void,
        release_send: *const fn (*Context, Types.Session) void,
        is_closing: *const fn (*Context, Types.Session) bool,
        finalize: *const fn (*Context, Types.Client) void,
        complete_delivery: *const fn (*Context, Types.Session, anyerror!void) Types.Completion,
        drop_client: *const fn (*Context, Types.Client) void,
        detach_after_send: *const fn (*Context, Types.Session, Types.Detach) void,
        should_close_after_reply: *const fn (*Context, Types.Session) bool,
        stopping: *const fn (*Context) bool,
        pump_client: *const fn (*Context, Types.Session) anyerror!void,
        pump_all: *const fn (*Context) void,
        shutdown_delivered: *const fn (*Context) bool,
    };
}

/// Creates a statically dispatched client-send completion coordinator.
///
/// ```zig
/// const ClientSendCoordinator = Coordinator(Context, Types, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime Types: type, comptime port: RuntimePort(Context, Types)) type {
    return struct {
        const Self = @This();
        const Event = SentEvent(Types);

        context: *Context,

        /// Binds send-completion policy to one runtime instance.
        ///
        /// ```zig
        /// var coordinator = ClientSendCoordinator.init(&context);
        /// ```
        pub fn init(context: *Context) Self {
            return .{ .context = context };
        }

        /// Releases the completed send borrow before applying delivery state.
        /// Closing and failed clients are finalized first; successful effects
        /// apply deferred detach and close-after-reply policy before retrying
        /// delivery. During shutdown, the return value reports whether every
        /// client has received or abandoned its stopping message.
        ///
        /// ```zig
        /// if (coordinator.handle(event)) {
        ///     return;
        /// }
        /// ```
        pub fn handle(coordinator: *Self, event: Event) bool {
            const session = port.resolve(coordinator.context, event.client) orelse {
                port.record_stale(coordinator.context);
                return false;
            };

            port.release_send(coordinator.context, session);
            if (port.is_closing(coordinator.context, session)) {
                port.finalize(coordinator.context, event.client);
                return port.shutdown_delivered(coordinator.context);
            }

            const completion = port.complete_delivery(coordinator.context, session, event.result);
            if (completion.close_client) {
                port.drop_client(coordinator.context, event.client);
                return port.shutdown_delivered(coordinator.context);
            }

            if (completion.detach_pane) |detach| {
                port.detach_after_send(coordinator.context, session, detach);
            }

            if (port.should_close_after_reply(coordinator.context, session) and
                !port.stopping(coordinator.context))
            {
                port.drop_client(coordinator.context, event.client);
                return false;
            }

            port.pump_client(coordinator.context, session) catch {
                port.drop_client(coordinator.context, event.client);
            };

            if (!port.stopping(coordinator.context)) {
                return false;
            }

            port.pump_all(coordinator.context);
            return port.shutdown_delivered(coordinator.context);
        }
    };
}

const FakeSession = struct {
    send_pending: bool = true,
    closing: bool = false,
    close_after_reply: bool = false,
};

const FakeCompletion = struct {
    detach_pane: ?u8 = null,
    close_client: bool = false,
};

const TestTypes = struct {
    pub const Client = u8;
    pub const Session = *FakeSession;
    pub const Completion = FakeCompletion;
    pub const Detach = u8;
};

const Step = enum {
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

const Capture = struct {
    steps: [16]Step = undefined,
    len: usize = 0,
    resolved_client: u8 = 7,
    resolve_client: bool = true,
    session: FakeSession = .{},
    completion: FakeCompletion = .{},
    runtime_stopping: bool = false,
    pump_failure: bool = false,
    shutdown_complete: bool = false,
    completion_saw_failure: bool = false,
    finalized_client: ?u8 = null,
    dropped_client: ?u8 = null,
    detached_pane: ?u8 = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn resolve(capture: *Capture, client: u8) ?*FakeSession {
        capture.record(.resolve);

        if (!capture.resolve_client or client != capture.resolved_client) {
            return null;
        }

        return &capture.session;
    }

    fn recordStale(capture: *Capture) void {
        capture.record(.record_stale);
    }

    fn releaseSend(capture: *Capture, session: *FakeSession) void {
        capture.record(.release_send);
        session.send_pending = false;
    }

    fn isClosing(capture: *Capture, session: *FakeSession) bool {
        capture.record(.is_closing);
        return session.closing;
    }

    fn finalize(capture: *Capture, client: u8) void {
        capture.record(.finalize);
        capture.finalized_client = client;
    }

    fn completeDelivery(capture: *Capture, _: *FakeSession, result: anyerror!void) FakeCompletion {
        capture.record(.complete_delivery);
        capture.completion_saw_failure = if (result) |_| false else |_| true;
        return capture.completion;
    }

    fn dropClient(capture: *Capture, client: u8) void {
        capture.record(.drop_client);
        capture.dropped_client = client;
    }

    fn detachAfterSend(capture: *Capture, _: *FakeSession, pane: u8) void {
        capture.record(.detach_after_send);
        capture.detached_pane = pane;
    }

    fn shouldCloseAfterReply(capture: *Capture, session: *FakeSession) bool {
        capture.record(.should_close_after_reply);
        return session.close_after_reply;
    }

    fn stopping(capture: *Capture) bool {
        capture.record(.stopping);
        return capture.runtime_stopping;
    }

    fn pumpClient(capture: *Capture, _: *FakeSession) !void {
        capture.record(.pump_client);

        if (capture.pump_failure) {
            return error.SendFailed;
        }
    }

    fn pumpAll(capture: *Capture) void {
        capture.record(.pump_all);
    }

    fn shutdownDelivered(capture: *Capture) bool {
        capture.record(.shutdown_delivered);
        return capture.shutdown_complete;
    }
};

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
