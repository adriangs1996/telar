const ConnectionIntegration = @This();
const FakeSession = @import("test_support.zig").FakeSession;
const source_namespace = @import("root.zig");
const std = @import("std");
const IgnoreTestObserver = @import("IgnoreTestObserver.zig");
session: FakeSession,
request_classes: [2]source_namespace.RequestClass = undefined,
request_count: usize = 0,
response_statuses: [2]u16 = undefined,
response_count: usize = 0,
failure_count: usize = 0,
upgraded: bool = false,

pub fn io(_: *ConnectionIntegration) std.Io {
    return std.testing.io;
}

pub fn readRequest(context: *ConnectionIntegration) ?source_namespace.RequestHead {
    const parsed = source_namespace.relayHead(&context.session, .{
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

pub fn relayRequestBody(context: *ConnectionIntegration, plan: source_namespace.BodyPlan) bool {
    return source_namespace.relayBody(
        &context.session,
        .{ .from = .child, .to = .origin, .framing = plan },
        IgnoreTestObserver{},
    );
}

pub fn relayResponse(context: *ConnectionIntegration, request: source_namespace.RequestHead) ?source_namespace.ResponseHead {
    while (true) {
        const parsed = source_namespace.relayHead(&context.session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = request.response_context == .head_request,
        }) orelse return null;

        if (!source_namespace.relayBody(
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

pub fn exchange(context: *ConnectionIntegration, request: source_namespace.RequestHead) source_namespace.ExchangeOutcome {
    return source_namespace.IntegrationExchange.execute(context, request);
}

pub fn publishRequest(context: *ConnectionIntegration, request: source_namespace.RequestHead) void {
    context.request_classes[context.request_count] = request.classification;
    context.request_count += 1;
}

pub fn publishResponse(context: *ConnectionIntegration, response: source_namespace.ResponseHead) void {
    context.response_statuses[context.response_count] = response.status_code;
    context.response_count += 1;
}

pub fn publishFailure(context: *ConnectionIntegration) void {
    context.failure_count += 1;
}

pub fn upgrade(context: *ConnectionIntegration) void {
    context.upgraded = true;
}
