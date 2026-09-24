const RequestHead = @import("RequestHead.zig");
const connection = @import("connection.zig");
const std = @import("std");
const ResponseHead = @import("ResponseHead.zig");
const ConnectionCapture = @This();

requests: [3]RequestHead = undefined,
request_len: usize = 0,
request_index: usize = 0,
outcomes: [3]connection.ExchangeOutcome = undefined,
outcome_index: usize = 0,
steps: [16]connection.Step = undefined,
step_len: usize = 0,
published_watched: ?bool = null,
published_status: ?u16 = null,

fn record(self: *ConnectionCapture, step: connection.Step) void {
    std.debug.assert(self.step_len < self.steps.len);
    self.steps[self.step_len] = step;
    self.step_len += 1;
}

pub fn readRequest(self: *ConnectionCapture) ?RequestHead {
    self.record(.read_request);

    if (self.request_index == self.request_len) {
        return null;
    }

    defer self.request_index += 1;
    return self.requests[self.request_index];
}

pub fn exchange(self: *ConnectionCapture, _: RequestHead) connection.ExchangeOutcome {
    self.record(.exchange);
    defer self.outcome_index += 1;
    return self.outcomes[self.outcome_index];
}

pub fn publishRequest(self: *ConnectionCapture, request: RequestHead) void {
    self.record(.publish_request);
    self.published_watched = request.watched;
}

pub fn publishResponse(self: *ConnectionCapture, final: ResponseHead) void {
    self.record(.publish_response);
    self.published_status = final.status_code;
}

pub fn publishFailure(self: *ConnectionCapture) void {
    self.record(.publish_failure);
}

pub fn upgrade(self: *ConnectionCapture) void {
    self.record(.upgrade);
}
