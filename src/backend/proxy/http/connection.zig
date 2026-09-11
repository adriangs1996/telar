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

pub const ExchangePort = @import("GenericExchangePort.zig").Type;

pub const Exchange = @import("GenericExchange.zig").Type;

pub const Port = @import("GenericPort.zig").Type;

pub const Connection = @import("GenericConnection.zig").Type;

pub const Event = union(enum) {
    request_body: bool,
    response: ?types.ResponseHead,
};

const ExchangeState = @import("ExchangeState.zig");

fn testingRequest(body: types.BodyPlan) types.RequestHead {
    return .{
        .classification = .inference,
        .body = body,
        .response_context = .normal,
    };
}

pub fn testingResponse(status_code: u16, kind: types.ResponseKind, connection: types.ConnectionPolicy) types.ResponseHead {
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

const ExchangeCapture = @import("ExchangeCapture.zig");

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

pub const Step = enum {
    read_request,
    publish_request,
    exchange,
    publish_response,
    publish_failure,
    upgrade,
};

const ConnectionCapture = @import("ConnectionCapture.zig");

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
