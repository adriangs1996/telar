const RequestHeadType = @import("RequestHead.zig");
const connection = @import("connection.zig");
const request_support = @import("../provider/request_support.zig");
const std = @import("std");
const ResponseHeadType = @import("ResponseHead.zig");
const ConnectionCapture = @This();

requests: [3]RequestHeadType = undefined,
request_len: usize = 0,
request_index: usize = 0,
outcomes: [3]connection.ExchangeOutcome = undefined,
outcome_index: usize = 0,
steps: [16]connection.Step = undefined,
step_len: usize = 0,
published_class: ?request_support.RequestClass = null,
published_status: ?u16 = null,

fn record(capture: *ConnectionCapture, step: connection.Step) void {
    std.debug.assert(capture.step_len < capture.steps.len);
    capture.steps[capture.step_len] = step;
    capture.step_len += 1;
}

pub fn readRequest(capture: *ConnectionCapture) ?RequestHeadType {
    capture.record(.read_request);

    if (capture.request_index == capture.request_len) {
        return null;
    }

    defer capture.request_index += 1;
    return capture.requests[capture.request_index];
}

pub fn exchange(capture: *ConnectionCapture, _: RequestHeadType) connection.ExchangeOutcome {
    capture.record(.exchange);
    defer capture.outcome_index += 1;
    return capture.outcomes[capture.outcome_index];
}

pub fn publishRequest(capture: *ConnectionCapture, request: RequestHeadType) void {
    capture.record(.publish_request);
    capture.published_class = request.classification;
}

pub fn publishResponse(capture: *ConnectionCapture, final: ResponseHeadType) void {
    capture.record(.publish_response);
    capture.published_status = final.status_code;
}

pub fn publishFailure(capture: *ConnectionCapture) void {
    capture.record(.publish_failure);
}

pub fn upgrade(capture: *ConnectionCapture) void {
    capture.record(.upgrade);
}
