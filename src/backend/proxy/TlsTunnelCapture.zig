const Capture = @This();
const source_namespace = @import("tls_tunnel.zig");
const tls = @import("tls.zig");
const std = @import("std");
const GenericAttempt = @import("GenericAttempt.zig").Type;
const GenericEstablished = @import("GenericEstablished.zig").Type;
steps: [5]source_namespace.Step = undefined,
len: usize = 0,
allow_interception: bool = false,
failure: ?tls.Error = null,
protocol: tls.Session.Protocol = .http11,
expected_host: []const u8 = "api.openai.com",
expected_child: u8 = 3,
expected_origin: u8 = 5,
recorded_failure: ?tls.Error = null,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn shouldIntercept(capture: *Capture, host: []const u8) bool {
    capture.record(.check_interception);
    std.debug.assert(std.mem.eql(u8, capture.expected_host, host));
    return capture.allow_interception;
}

pub fn recordPassthrough(capture: *Capture) void {
    capture.record(.record_passthrough);
}

pub fn intercept(capture: *Capture, attempt: GenericAttempt(u8)) tls.Error!GenericEstablished(u16) {
    capture.record(.intercept);
    std.debug.assert(std.mem.eql(u8, capture.expected_host, attempt.host));
    std.debug.assert(capture.expected_child == attempt.child);
    std.debug.assert(capture.expected_origin == attempt.origin);

    if (capture.failure) |failure| {
        return failure;
    }

    return .{ .session = 17, .protocol = capture.protocol };
}

pub fn recordFailure(capture: *Capture, failure: tls.Error) void {
    capture.record(.record_failure);
    capture.recorded_failure = failure;
}

pub fn publishFailure(capture: *Capture) void {
    capture.record(.publish_failure);
}
