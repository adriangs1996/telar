//! Passthrough and TLS interception policy for an authenticated CONNECT tunnel.

const std = @import("std");
const tls = @import("tls.zig");

pub fn Attempt(comptime Stream: type) type {
    return struct {
        host: []const u8,
        child: Stream,
        origin: Stream,
    };
}

pub fn Established(comptime Session: type) type {
    return struct {
        session: Session,
        protocol: tls.Session.Protocol,
    };
}

pub fn Route(comptime Session: type) type {
    return union(enum) {
        passthrough,
        http11: Session,
        h2: Session,
    };
}

/// Defines interception policy, TLS establishment, metrics, and failure
/// publication supplied by the proxy service.
///
/// ```zig
/// const port: Port(Context, Stream, Session) = .{ ... };
/// ```
pub fn Port(comptime Context: type, comptime Stream: type, comptime Session: type) type {
    return struct {
        pub const StreamType = Stream;
        pub const SessionType = Session;

        should_intercept: *const fn (*Context, []const u8) bool,
        record_passthrough: *const fn (*Context) void,
        intercept: *const fn (*Context, Attempt(Stream)) tls.Error!Established(Session),
        record_failure: *const fn (*Context, tls.Error) void,
        publish_failure: *const fn (*Context) void,
    };
}

/// Creates the policy command for one authenticated CONNECT tunnel.
///
/// ```zig
/// const EstablishTunnel = Command(Context, port);
/// const route = EstablishTunnel.execute(&context, attempt);
/// ```
pub fn Command(comptime Context: type, comptime port: anytype) type {
    const PortType = @TypeOf(port);
    const Stream = PortType.StreamType;
    const Session = PortType.SessionType;

    return struct {
        /// Passes every host through unless policy explicitly authorizes its
        /// interception. A successful interception transfers session ownership
        /// through an explicit HTTP/1.1 or HTTP/2 route. Every TLS failure
        /// records its exact stage, publishes one failed request, and returns
        /// `null`.
        ///
        /// ```zig
        /// const route = EstablishTunnel.execute(&context, attempt);
        /// ```
        pub fn execute(context: *Context, attempt: Attempt(Stream)) ?Route(Session) {
            if (!port.should_intercept(context, attempt.host)) {
                port.record_passthrough(context);
                return .passthrough;
            }

            const established = port.intercept(context, attempt) catch |failure| {
                port.record_failure(context, failure);
                port.publish_failure(context);
                return null;
            };

            return switch (established.protocol) {
                .http11 => .{ .http11 = established.session },
                .h2 => .{ .h2 = established.session },
            };
        }
    };
}

const Step = enum {
    check_interception,
    record_passthrough,
    intercept,
    record_failure,
    publish_failure,
};

const Capture = struct {
    steps: [5]Step = undefined,
    len: usize = 0,
    allow_interception: bool = false,
    failure: ?tls.Error = null,
    protocol: tls.Session.Protocol = .http11,
    expected_host: []const u8 = "api.openai.com",
    expected_child: u8 = 3,
    expected_origin: u8 = 5,
    recorded_failure: ?tls.Error = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn shouldIntercept(capture: *Capture, host: []const u8) bool {
        capture.record(.check_interception);
        std.debug.assert(std.mem.eql(u8, capture.expected_host, host));
        return capture.allow_interception;
    }

    fn recordPassthrough(capture: *Capture) void {
        capture.record(.record_passthrough);
    }

    fn intercept(capture: *Capture, attempt: Attempt(u8)) tls.Error!Established(u16) {
        capture.record(.intercept);
        std.debug.assert(std.mem.eql(u8, capture.expected_host, attempt.host));
        std.debug.assert(capture.expected_child == attempt.child);
        std.debug.assert(capture.expected_origin == attempt.origin);

        if (capture.failure) |failure| {
            return failure;
        }

        return .{ .session = 17, .protocol = capture.protocol };
    }

    fn recordFailure(capture: *Capture, failure: tls.Error) void {
        capture.record(.record_failure);
        capture.recorded_failure = failure;
    }

    fn publishFailure(capture: *Capture) void {
        capture.record(.publish_failure);
    }
};

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
