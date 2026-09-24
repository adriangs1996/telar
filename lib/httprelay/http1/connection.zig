//! HTTP/1.1 exchange concurrency and connection lifecycle.
//!
//! Parsing and byte relay stay behind ports. This module owns when request
//! bodies and responses run concurrently, which observations are published,
//! and whether the intercepted connection is reused, closed, or upgraded.

const GenericExchange = @import("GenericExchange.zig").Type;
const GenericConnection = @import("GenericConnection.zig").Type;
const ResponseHead = @import("ResponseHead.zig");
const types = @import("types.zig");
const RequestHead = @import("RequestHead.zig");
const ExchangeState = @import("ExchangeState.zig");
const std = @import("std");
const ExchangeCapture = @import("ExchangeCapture.zig");
const ConnectionCapture = @import("ConnectionCapture.zig");

pub const ExchangeOutcome = union(enum) {
    complete: ResponseHead,
    early_response: ResponseHead,
    failed,
};

pub const Event = union(enum) {
    request_body: bool,
    response: ?ResponseHead,
};

fn testingRequest(body: types.BodyPlan) RequestHead {
    return .{
        .watched = true,
        .body = body,
        .response_context = .normal,
    };
}

pub fn testingResponse(status_code: u16, kind: types.ResponseKind, connection: types.ConnectionPolicy) ResponseHead {
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

const TestExchange = GenericExchange(ExchangeCapture);

test "bodyless exchange never schedules a body relay" {
    var capture: ExchangeCapture = .{};

    try std.testing.expectEqualDeep(
        ExchangeOutcome{ .complete = testingResponse(200, .final, .keep_alive) },
        TestExchange.execute(std.testing.io, &capture, testingRequest(.none)),
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
        TestExchange.execute(std.testing.io, &capture, testingRequest(.{ .content_length = 4 })),
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
        TestExchange.execute(std.testing.io, &capture, testingRequest(.{ .content_length = 4 })),
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
        TestExchange.execute(std.testing.io, &capture, testingRequest(.{ .content_length = 4 })),
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

const TestConnection = GenericConnection(ConnectionCapture);

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
        .watched = false,
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
    try std.testing.expectEqual(false, capture.published_watched.?);
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
