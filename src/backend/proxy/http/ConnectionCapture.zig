const ConnectionCapture = @This();
const types = @import("types.zig");
const source_namespace = @import("connection.zig");
const std = @import("std");
requests: [3]types.RequestHead = undefined,
request_len: usize = 0,
request_index: usize = 0,
outcomes: [3]source_namespace.ExchangeOutcome = undefined,
outcome_index: usize = 0,
steps: [16]source_namespace.Step = undefined,
step_len: usize = 0,
published_class: ?types.RequestClass = null,
published_status: ?u16 = null,

fn record(capture: *ConnectionCapture, step: source_namespace.Step) void {
    std.debug.assert(capture.step_len < capture.steps.len);
    capture.steps[capture.step_len] = step;
    capture.step_len += 1;
}

pub fn readRequest(capture: *ConnectionCapture) ?types.RequestHead {
    capture.record(.read_request);

    if (capture.request_index == capture.request_len) {
        return null;
    }

    defer capture.request_index += 1;
    return capture.requests[capture.request_index];
}

pub fn exchange(capture: *ConnectionCapture, _: types.RequestHead) source_namespace.ExchangeOutcome {
    capture.record(.exchange);
    defer capture.outcome_index += 1;
    return capture.outcomes[capture.outcome_index];
}

pub fn publishRequest(capture: *ConnectionCapture, request: types.RequestHead) void {
    capture.record(.publish_request);
    capture.published_class = request.classification;
}

pub fn publishResponse(capture: *ConnectionCapture, final: types.ResponseHead) void {
    capture.record(.publish_response);
    capture.published_status = final.status_code;
}

pub fn publishFailure(capture: *ConnectionCapture) void {
    capture.record(.publish_failure);
}

pub fn upgrade(capture: *ConnectionCapture) void {
    capture.record(.upgrade);
}
