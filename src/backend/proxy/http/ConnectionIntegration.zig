const FakeSession = @import("FakeSession.zig");
const request_support = @import("../provider/request_support.zig");
const std = @import("std");
const RequestHeadType = @import("RequestHead.zig");
const http = @import("http.zig");
const types = @import("types.zig");
const IgnoreTestObserver = @import("IgnoreTestObserver.zig");
const ResponseHeadType = @import("ResponseHead.zig");
const connection_module = @import("connection.zig");
const ConnectionIntegration = @This();

session: FakeSession,
request_classes: [2]request_support.RequestClass = undefined,
request_count: usize = 0,
response_statuses: [2]u16 = undefined,
response_count: usize = 0,
failure_count: usize = 0,
upgraded: bool = false,

pub fn io(_: *ConnectionIntegration) std.Io {
    return std.testing.io;
}

pub fn readRequest(context: *ConnectionIntegration) ?RequestHeadType {
    const parsed = http.relayHead(&context.session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
        .dialect = .anthropic_messages,
    }) orelse return null;

    return .{
        .classification = parsed.classification,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}

pub fn relayRequestBody(context: *ConnectionIntegration, plan: types.BodyPlan) bool {
    return http.relayBody(
        &context.session,
        .{ .from = .child, .to = .origin, .framing = plan },
        IgnoreTestObserver{},
    );
}

pub fn relayResponse(context: *ConnectionIntegration, request: RequestHeadType) ?ResponseHeadType {
    while (true) {
        const parsed = http.relayHead(&context.session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = request.response_context == .head_request,
        }) orelse return null;

        if (!http.relayBody(
            &context.session,
            .{ .from = .origin, .to = .child, .framing = parsed.framing },
            IgnoreTestObserver{},
        )) {
            return null;
        }

        if (parsed.message.informational) {
            continue;
        }

        return .{
            .status_code = parsed.message.status_code,
            .body = parsed.framing,
            .kind = if (parsed.message.upgrade) .upgrade else .final,
            .connection = if (parsed.message.closes) .close else .keep_alive,
        };
    }
}

pub fn exchange(context: *ConnectionIntegration, request: RequestHeadType) connection_module.ExchangeOutcome {
    return http.IntegrationExchange.execute(context, request);
}

pub fn publishRequest(context: *ConnectionIntegration, request: RequestHeadType) void {
    context.request_classes[context.request_count] = request.classification;
    context.request_count += 1;
}

pub fn publishResponse(context: *ConnectionIntegration, response: ResponseHeadType) void {
    context.response_statuses[context.response_count] = response.status_code;
    context.response_count += 1;
}

pub fn publishFailure(context: *ConnectionIntegration) void {
    context.failure_count += 1;
}

pub fn upgrade(context: *ConnectionIntegration) void {
    context.upgraded = true;
}
