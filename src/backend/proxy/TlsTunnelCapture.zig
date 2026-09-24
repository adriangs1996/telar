const tls_tunnel = @import("tls_tunnel.zig");
const localca = @import("localca");
const tls = localca.tls;
const Session = localca.Session;
const std = @import("std");
const GenericAttempt = @import("GenericAttempt.zig").Type;
const GenericEstablished = @import("GenericEstablished.zig").Type;
const Capture = @This();

steps: [5]tls_tunnel.Step = undefined,
len: usize = 0,
allow_interception: bool = false,
failure: ?tls.Error = null,
protocol: Session.Protocol = .http11,
expected_host: []const u8 = "api.openai.com",
expected_child: u8 = 3,
expected_origin: u8 = 5,
recorded_failure: ?tls.Error = null,

fn record(self: *Capture, step: tls_tunnel.Step) void {
    std.debug.assert(self.len < self.steps.len);
    self.steps[self.len] = step;
    self.len += 1;
}

pub fn shouldIntercept(self: *Capture, host: []const u8) bool {
    self.record(.check_interception);
    std.debug.assert(std.mem.eql(u8, self.expected_host, host));
    return self.allow_interception;
}

pub fn recordPassthrough(self: *Capture) void {
    self.record(.record_passthrough);
}

pub fn intercept(self: *Capture, attempt: GenericAttempt(u8)) tls.Error!GenericEstablished(u16) {
    self.record(.intercept);
    std.debug.assert(std.mem.eql(u8, self.expected_host, attempt.host));
    std.debug.assert(self.expected_child == attempt.child);
    std.debug.assert(self.expected_origin == attempt.origin);

    if (self.failure) |failure| {
        return failure;
    }

    return .{ .session = 17, .protocol = self.protocol };
}

pub fn recordFailure(self: *Capture, failure: tls.Error) void {
    self.record(.record_failure);
    self.recorded_failure = failure;
}

pub fn publishFailure(self: *Capture) void {
    self.record(.publish_failure);
}
