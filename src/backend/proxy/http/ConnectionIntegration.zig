const FakeSession = @import("FakeSession.zig");
const RouteMatch = @import("../RouteMatch.zig");
const std = @import("std");
const RequestHead = @import("RequestHead.zig");
const http = @import("http.zig");
const types = @import("types.zig");
const IgnoreTestObserver = @import("IgnoreTestObserver.zig");
const ResponseHead = @import("ResponseHead.zig");
const connection_module = @import("connection.zig");
const ConnectionIntegration = @This();

const watched_routes = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/messages"} }};

session: FakeSession,
watched: [2]bool = undefined,
request_count: usize = 0,
response_statuses: [2]u16 = undefined,
response_count: usize = 0,
failure_count: usize = 0,
upgraded: bool = false,

pub fn io(_: *ConnectionIntegration) std.Io {
    return std.testing.io;
}

pub fn readRequest(self: *ConnectionIntegration) ?RequestHead {
    const parsed = http.relayHead(&self.session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
        .watched_routes = &watched_routes,
    }) orelse return null;

    return .{
        .watched = parsed.watched,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}

pub fn relayRequestBody(self: *ConnectionIntegration, plan: types.BodyPlan) bool {
    return http.relayBody(
        &self.session,
        .{ .from = .child, .to = .origin, .framing = plan },
        IgnoreTestObserver{},
    );
}

pub fn relayResponse(self: *ConnectionIntegration, request: RequestHead) ?ResponseHead {
    while (true) {
        const parsed = http.relayHead(&self.session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = request.response_context == .head_request,
        }) orelse return null;

        if (!http.relayBody(
            &self.session,
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

pub fn exchange(self: *ConnectionIntegration, request: RequestHead) connection_module.ExchangeOutcome {
    return http.IntegrationExchange.execute(self, request);
}

pub fn publishRequest(self: *ConnectionIntegration, request: RequestHead) void {
    self.watched[self.request_count] = request.watched;
    self.request_count += 1;
}

pub fn publishResponse(self: *ConnectionIntegration, response: ResponseHead) void {
    self.response_statuses[self.response_count] = response.status_code;
    self.response_count += 1;
}

pub fn publishFailure(self: *ConnectionIntegration) void {
    self.failure_count += 1;
}

pub fn upgrade(self: *ConnectionIntegration) void {
    self.upgraded = true;
}
