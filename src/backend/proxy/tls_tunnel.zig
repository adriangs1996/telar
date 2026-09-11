//! Passthrough and TLS interception policy for an authenticated CONNECT tunnel.

const GenericAttempt = @import("GenericAttempt.zig").Type;

const GenericTlsTunnelPort = @import("GenericTlsTunnelPort.zig").Type;
const GenericTlsTunnelCommand = @import("GenericTlsTunnelCommand.zig").Type;
const TlsTunnelCapture = @import("TlsTunnelCapture.zig");
const std = @import("std");
const tls = @import("tls.zig");

pub const Step = enum {
    check_interception,
    record_passthrough,
    intercept,
    record_failure,
    publish_failure,
};

const test_port: GenericTlsTunnelPort(TlsTunnelCapture, u8, u16) = .{
    .should_intercept = TlsTunnelCapture.shouldIntercept,
    .record_passthrough = TlsTunnelCapture.recordPassthrough,
    .intercept = TlsTunnelCapture.intercept,
    .record_failure = TlsTunnelCapture.recordFailure,
    .publish_failure = TlsTunnelCapture.publishFailure,
};

const TestCommand = GenericTlsTunnelCommand(TlsTunnelCapture, test_port);

fn testAttempt() GenericAttempt(u8) {
    return .{ .host = "api.openai.com", .child = 3, .origin = 5 };
}

fn expectSteps(capture: *const TlsTunnelCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a host outside the allowlist avoids every TLS operation" {
    var capture: TlsTunnelCapture = .{};

    const route = TestCommand.execute(&capture, testAttempt()).?;

    try std.testing.expect(route == .passthrough);
    try expectSteps(&capture, &.{ .check_interception, .record_passthrough });
}

test "HTTP11 negotiation transfers the established session" {
    var capture: TlsTunnelCapture = .{ .allow_interception = true, .protocol = .http11 };

    const route = TestCommand.execute(&capture, testAttempt()).?;

    const session = switch (route) {
        .http11 => |value| value,
        else => return error.ExpectedHttp11Route,
    };
    try std.testing.expectEqual(@as(u16, 17), session);
    try expectSteps(&capture, &.{ .check_interception, .intercept });
}

test "HTTP2 negotiation transfers the established session" {
    var capture: TlsTunnelCapture = .{ .allow_interception = true, .protocol = .h2 };

    const route = TestCommand.execute(&capture, testAttempt()).?;

    const session = switch (route) {
        .h2 => |value| value,
        else => return error.ExpectedH2Route,
    };
    try std.testing.expectEqual(@as(u16, 17), session);
    try expectSteps(&capture, &.{ .check_interception, .intercept });
}

test "every TLS establishment failure records and publishes exactly once" {
    const failures = [_]tls.Error{
        error.ContextFailed,
        error.UpstreamHandshakeFailed,
        error.DownstreamHandshakeFailed,
        error.MintFailed,
    };

    for (failures) |failure| {
        var capture: TlsTunnelCapture = .{ .allow_interception = true, .failure = failure };

        try std.testing.expect(TestCommand.execute(&capture, testAttempt()) == null);

        try expectSteps(&capture, &.{ .check_interception, .intercept, .record_failure, .publish_failure });
        try std.testing.expectEqual(failure, capture.recorded_failure.?);
    }
}
