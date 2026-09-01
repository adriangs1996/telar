//! HTTP/1.1 exchange concurrency and connection lifecycle.
//!
//! Parsing and byte relay stay behind ports. This module owns when request
//! bodies and responses run concurrently, which observations are published,
//! and whether the intercepted connection is reused, closed, or upgraded.

const std = @import("std");
const types = @import("types.zig");

pub const ExchangeOutcome = union(enum) {
    complete: types.ResponseHead,
    early_response: types.ResponseHead,
    failed,
};

/// Supplies the I/O operations needed to finish one request/response pair.
///
/// ```zig
/// const port: ExchangePort(Context) = .{
///     .io = Context.io,
///     .relay_body = Context.relayBody,
///     .relay_response = Context.relayResponse,
/// };
/// ```
pub fn ExchangePort(comptime Context: type) type {
    return struct {
        io: *const fn (*Context) std.Io,
        relay_body: *const fn (*Context, types.BodyPlan) bool,
        relay_response: *const fn (*Context, types.RequestHead) ?types.ResponseHead,
    };
}

/// Creates the executor for one HTTP/1.1 exchange.
///
/// ```zig
/// const RelayExchange = Exchange(Context, exchange_port);
/// const outcome = RelayExchange.execute(&context, request);
/// ```
pub fn Exchange(comptime Context: type, comptime port: anytype) type {
    return struct {
        /// Relays a bodyless response synchronously. When a request has a body,
        /// the upload and response race so an origin may reject the upload
        /// early. Every unfinished task is cancelled before returning.
        ///
        /// ```zig
        /// const outcome = RelayExchange.execute(&context, request);
        /// ```
        pub fn execute(context: *Context, request: types.RequestHead) ExchangeOutcome {
            if (!request.body.hasBody()) {
                const response = port.relay_response(context, request) orelse return .failed;
                return .{ .complete = response };
            }

            const io = port.io(context);
            var event_storage: [2]Event = undefined;
            var workers = std.Io.Select(Event).init(io, &event_storage);
            workers.concurrent(.request_body, relayBody, .{ context, request.body }) catch return .failed;
            workers.concurrent(.response, relayResponse, .{ context, request }) catch {
                workers.cancelDiscard();
                return .failed;
            };
            defer workers.cancelDiscard();

            var state: ExchangeState = .{};

            while (true) {
                const event = workers.await() catch return .failed;

                if (state.accept(event)) |outcome| {
                    return outcome;
                }
            }
        }

        fn relayBody(context: *Context, body: types.BodyPlan) bool {
            return port.relay_body(context, body);
        }

        fn relayResponse(context: *Context, request: types.RequestHead) ?types.ResponseHead {
            return port.relay_response(context, request);
        }
    };
}

/// Supplies semantic operations for one reusable HTTP/1.1 connection.
///
/// ```zig
/// const port: Port(Context) = .{ ... };
/// ```
pub fn Port(comptime Context: type) type {
    return struct {
        read_request: *const fn (*Context) ?types.RequestHead,
        exchange: *const fn (*Context, types.RequestHead) ExchangeOutcome,
        publish_request: *const fn (*Context, types.RequestHead) void,
        publish_response: *const fn (*Context, types.ResponseHead) void,
        publish_failure: *const fn (*Context) void,
        upgrade: *const fn (*Context) void,
    };
}

/// Creates the lifecycle runner for one intercepted HTTP/1.1 connection.
///
/// ```zig
/// const HttpConnection = Connection(Context, port);
/// HttpConnection.run(&context);
/// ```
pub fn Connection(comptime Context: type, comptime port: anytype) type {
    return struct {
        /// Runs exchanges until input ends, an exchange fails, a response
        /// closes the connection, or a successful exchange upgrades it.
        /// Request publication always precedes its exchange; final response
        /// publication always precedes close or upgrade.
        ///
        /// ```zig
        /// HttpConnection.run(&context);
        /// ```
        pub fn run(context: *Context) void {
            while (port.read_request(context)) |request| {
                port.publish_request(context, request);

                switch (port.exchange(context, request)) {
                    .failed => {
                        port.publish_failure(context);
                        return;
                    },
                    .early_response => |response| {
                        if (!publishFinal(context, response)) {
                            return;
                        }

                        return;
                    },
                    .complete => |response| {
                        if (!publishFinal(context, response)) {
                            return;
                        }

                        switch (response.kind) {
                            .informational => unreachable,
                            .upgrade => {
                                port.upgrade(context);
                                return;
                            },
                            .final => if (response.connection == .close) {
                                return;
                            },
                        }
                    },
                }
            }
        }

        fn publishFinal(context: *Context, response: types.ResponseHead) bool {
            if (response.kind == .informational) {
                port.publish_failure(context);
                return false;
            }

            port.publish_response(context, response);
            return true;
        }
    };
}

const Event = union(enum) {
    request_body: bool,
    response: ?types.ResponseHead,
};

const ExchangeState = struct {
    body_finished: bool = false,

    fn accept(state: *ExchangeState, event: Event) ?ExchangeOutcome {
        return switch (event) {
            .request_body => |forwarded| block: {
                if (!forwarded) {
                    break :block .failed;
                }

                state.body_finished = true;
                break :block null;
            },
            .response => |candidate| block: {
                const final = candidate orelse break :block .failed;

                break :block if (state.body_finished)
                    .{ .complete = final }
                else
                    .{ .early_response = final };
            },
        };
    }
};

fn testingRequest(body: types.BodyPlan) types.RequestHead {
    return .{
        .classification = .inference,
        .body = body,
        .response_context = .normal,
    };
}

fn testingResponse(status_code: u16, kind: types.ResponseKind, connection: types.ConnectionPolicy) types.ResponseHead {
    return .{
        .status_code = status_code,
        .body = .none,
        .kind = kind,
        .connection = connection,
    };
}

test "exchange state distinguishes completed and early responses" {
    const final = testingResponse(200, .final, .keep_alive);
    var body_first: ExchangeState = .{};

    try std.testing.expect(body_first.accept(.{ .request_body = true }) == null);
    try std.testing.expectEqualDeep(
        ExchangeOutcome{ .complete = final },
        body_first.accept(.{ .response = final }).?,
    );

    var response_first: ExchangeState = .{};
    try std.testing.expectEqualDeep(
        ExchangeOutcome{ .early_response = final },
        response_first.accept(.{ .response = final }).?,
    );
}

test "exchange state rejects either failed relay" {
    var body_failed: ExchangeState = .{};
    try std.testing.expectEqual(ExchangeOutcome.failed, body_failed.accept(.{ .request_body = false }).?);

    var response_failed: ExchangeState = .{};
    try std.testing.expectEqual(ExchangeOutcome.failed, response_failed.accept(.{ .response = null }).?);
}

const ExchangeCapture = struct {
    body_calls: std.atomic.Value(u32) = .init(0),
    response_calls: std.atomic.Value(u32) = .init(0),
    body_started: ?*std.Io.Queue(u8) = null,
    body_release: ?*std.Io.Queue(u8) = null,
    response_started: ?*std.Io.Queue(u8) = null,
    response_release: ?*std.Io.Queue(u8) = null,
    body_result: bool = true,
    body_canceled: std.atomic.Value(bool) = .init(false),
    response_canceled: std.atomic.Value(bool) = .init(false),
    response: ?types.ResponseHead = testingResponse(200, .final, .keep_alive),

    fn io(_: *ExchangeCapture) std.Io {
        return std.testing.io;
    }

    fn relayBody(capture: *ExchangeCapture, _: types.BodyPlan) bool {
        _ = capture.body_calls.fetchAdd(1, .monotonic);

        if (capture.response_started) |started| {
            _ = started.getOne(std.testing.io) catch return false;
        }

        if (capture.body_started) |started| {
            started.putOneUncancelable(std.testing.io, 0) catch return false;
        }

        if (capture.body_release) |release| {
            _ = release.getOne(std.testing.io) catch {
                capture.body_canceled.store(true, .monotonic);
                return false;
            };
        }

        return capture.body_result;
    }

    fn relayResponse(capture: *ExchangeCapture, _: types.RequestHead) ?types.ResponseHead {
        _ = capture.response_calls.fetchAdd(1, .monotonic);

        if (capture.body_started) |started| {
            _ = started.getOne(std.testing.io) catch return null;
        }

        if (capture.response_started) |started| {
            started.putOneUncancelable(std.testing.io, 0) catch return null;
        }

        if (capture.response_release) |release| {
            _ = release.getOne(std.testing.io) catch {
                capture.response_canceled.store(true, .monotonic);
                return null;
            };
        }

        return capture.response;
    }
};

const exchange_test_port: ExchangePort(ExchangeCapture) = .{
    .io = ExchangeCapture.io,
    .relay_body = ExchangeCapture.relayBody,
    .relay_response = ExchangeCapture.relayResponse,
};

const TestExchange = Exchange(ExchangeCapture, exchange_test_port);

test "bodyless exchange never schedules a body relay" {
    var capture: ExchangeCapture = .{};

    try std.testing.expectEqualDeep(
        ExchangeOutcome{ .complete = testingResponse(200, .final, .keep_alive) },
        TestExchange.execute(&capture, testingRequest(.none)),
    );
    try std.testing.expectEqual(@as(u32, 0), capture.body_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), capture.response_calls.load(.monotonic));
}

test "an early response cancels an unfinished request body" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: ExchangeCapture = .{
        .body_started = &started,
        .body_release = &release,
    };

    try std.testing.expectEqualDeep(
        ExchangeOutcome{ .early_response = testingResponse(200, .final, .keep_alive) },
        TestExchange.execute(&capture, testingRequest(.{ .content_length = 4 })),
    );
    try std.testing.expectEqual(@as(u32, 1), capture.body_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), capture.response_calls.load(.monotonic));
    try std.testing.expect(capture.body_canceled.load(.monotonic));
}

test "a failed response cancels an unfinished request body" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: ExchangeCapture = .{
        .body_started = &started,
        .body_release = &release,
        .response = null,
    };

    try std.testing.expectEqual(
        ExchangeOutcome.failed,
        TestExchange.execute(&capture, testingRequest(.{ .content_length = 4 })),
    );
    try std.testing.expect(capture.body_canceled.load(.monotonic));
}

test "a failed request body cancels an unfinished response" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: ExchangeCapture = .{
        .response_started = &started,
        .response_release = &release,
        .body_result = false,
    };

    try std.testing.expectEqual(
        ExchangeOutcome.failed,
        TestExchange.execute(&capture, testingRequest(.{ .content_length = 4 })),
    );
    try std.testing.expect(capture.response_canceled.load(.monotonic));
}

const Step = enum {
    read_request,
    publish_request,
    exchange,
    publish_response,
    publish_failure,
    upgrade,
};

const ConnectionCapture = struct {
    requests: [3]types.RequestHead = undefined,
    request_len: usize = 0,
    request_index: usize = 0,
    outcomes: [3]ExchangeOutcome = undefined,
    outcome_index: usize = 0,
    steps: [16]Step = undefined,
    step_len: usize = 0,
    published_class: ?types.RequestClass = null,
    published_status: ?u16 = null,

    fn record(capture: *ConnectionCapture, step: Step) void {
        std.debug.assert(capture.step_len < capture.steps.len);
        capture.steps[capture.step_len] = step;
        capture.step_len += 1;
    }

    fn readRequest(capture: *ConnectionCapture) ?types.RequestHead {
        capture.record(.read_request);

        if (capture.request_index == capture.request_len) {
            return null;
        }

        defer capture.request_index += 1;
        return capture.requests[capture.request_index];
    }

    fn exchange(capture: *ConnectionCapture, _: types.RequestHead) ExchangeOutcome {
        capture.record(.exchange);
        defer capture.outcome_index += 1;
        return capture.outcomes[capture.outcome_index];
    }

    fn publishRequest(capture: *ConnectionCapture, request: types.RequestHead) void {
        capture.record(.publish_request);
        capture.published_class = request.classification;
    }

    fn publishResponse(capture: *ConnectionCapture, final: types.ResponseHead) void {
        capture.record(.publish_response);
        capture.published_status = final.status_code;
    }

    fn publishFailure(capture: *ConnectionCapture) void {
        capture.record(.publish_failure);
    }

    fn upgrade(capture: *ConnectionCapture) void {
        capture.record(.upgrade);
    }
};

const connection_test_port: Port(ConnectionCapture) = .{
    .read_request = ConnectionCapture.readRequest,
    .exchange = ConnectionCapture.exchange,
    .publish_request = ConnectionCapture.publishRequest,
    .publish_response = ConnectionCapture.publishResponse,
    .publish_failure = ConnectionCapture.publishFailure,
    .upgrade = ConnectionCapture.upgrade,
};

const TestConnection = Connection(ConnectionCapture, connection_test_port);

fn expectSteps(capture: *const ConnectionCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.step_len]);
}

test "input EOF ends an idle HTTP connection without an observation" {
    var capture: ConnectionCapture = .{};

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{.read_request});
}

test "a keep-alive response permits the next exchange" {
    var capture: ConnectionCapture = .{};
    capture.requests[0] = testingRequest(.none);
    capture.requests[1] = .{
        .classification = .auxiliary,
        .body = .none,
        .response_context = .normal,
    };
    capture.request_len = 2;
    capture.outcomes[0] = .{ .complete = testingResponse(200, .final, .keep_alive) };
    capture.outcomes[1] = .{ .complete = testingResponse(204, .final, .close) };

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{
        .read_request,
        .publish_request,
        .exchange,
        .publish_response,
        .read_request,
        .publish_request,
        .exchange,
        .publish_response,
    });
    try std.testing.expectEqual(types.RequestClass.auxiliary, capture.published_class.?);
    try std.testing.expectEqual(@as(u16, 204), capture.published_status.?);
}

test "an exchange failure publishes exactly one failure and stops" {
    var capture: ConnectionCapture = .{};
    capture.requests[0] = testingRequest(.{ .content_length = 4 });
    capture.request_len = 1;
    capture.outcomes[0] = .failed;

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{
        .read_request,
        .publish_request,
        .exchange,
        .publish_failure,
    });
}

test "an early response is published and forces connection close" {
    var capture: ConnectionCapture = .{};
    capture.requests[0] = testingRequest(.{ .content_length = 4 });
    capture.request_len = 1;
    capture.outcomes[0] = .{ .early_response = testingResponse(413, .final, .keep_alive) };

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{
        .read_request,
        .publish_request,
        .exchange,
        .publish_response,
    });
    try std.testing.expectEqual(@as(u16, 413), capture.published_status.?);
}

test "a complete upgrade publishes before transferring the connection" {
    var capture: ConnectionCapture = .{};
    capture.requests[0] = testingRequest(.none);
    capture.request_len = 1;
    capture.outcomes[0] = .{ .complete = testingResponse(101, .upgrade, .keep_alive) };

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{
        .read_request,
        .publish_request,
        .exchange,
        .publish_response,
        .upgrade,
    });
}

test "an informational result violates the exchange contract" {
    var capture: ConnectionCapture = .{};
    capture.requests[0] = testingRequest(.none);
    capture.request_len = 1;
    capture.outcomes[0] = .{ .complete = testingResponse(100, .informational, .keep_alive) };

    TestConnection.run(&capture);

    try expectSteps(&capture, &.{
        .read_request,
        .publish_request,
        .exchange,
        .publish_failure,
    });
}
