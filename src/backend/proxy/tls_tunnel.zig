//! Passthrough and TLS interception policy for an authenticated CONNECT tunnel.

const std = @import("std");
const tls = @import("tls.zig");

pub const Attempt = @import("GenericAttempt.zig").Type;

pub const Established = @import("GenericEstablished.zig").Type;

pub const Route = @import("GenericRoute.zig").Type;

pub const Port = @import("GenericTlsTunnelPort.zig").Type;

pub const Command = @import("GenericTlsTunnelCommand.zig").Type;

pub const Step = enum {
    check_interception,
    record_passthrough,
    intercept,
    record_failure,
    publish_failure,
};

const Capture = @import("TlsTunnelCapture.zig");

const test_port: Port(Capture, u8, u16) = .{
    .should_intercept = Capture.shouldIntercept,
    .record_passthrough = Capture.recordPassthrough,
    .intercept = Capture.intercept,
    .record_failure = Capture.recordFailure,
    .publish_failure = Capture.publishFailure,
};

const TestCommand = Command(Capture, test_port);

fn testAttempt() Attempt(u8) {
    return .{ .host = "api.openai.com", .child = 3, .origin = 5 };
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a host outside the allowlist avoids every TLS operation" {
    var capture: Capture = .{};

    const route = TestCommand.execute(&capture, testAttempt()).?;

    try std.testing.expect(route == .passthrough);
    try expectSteps(&capture, &.{ .check_interception, .record_passthrough });
}

test "HTTP11 negotiation transfers the established session" {
    var capture: Capture = .{ .allow_interception = true, .protocol = .http11 };

    const route = TestCommand.execute(&capture, testAttempt()).?;

    const session = switch (route) {
        .http11 => |value| value,
        else => return error.ExpectedHttp11Route,
    };
    try std.testing.expectEqual(@as(u16, 17), session);
    try expectSteps(&capture, &.{ .check_interception, .intercept });
}

test "HTTP2 negotiation transfers the established session" {
    var capture: Capture = .{ .allow_interception = true, .protocol = .h2 };

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
        var capture: Capture = .{ .allow_interception = true, .failure = failure };

        try std.testing.expect(TestCommand.execute(&capture, testAttempt()) == null);

        try expectSteps(&capture, &.{ .check_interception, .intercept, .record_failure, .publish_failure });
        try std.testing.expectEqual(failure, capture.recorded_failure.?);
    }
}
