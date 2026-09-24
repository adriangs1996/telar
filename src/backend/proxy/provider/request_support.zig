//! Request classification by API dialect.

const httprelay = @import("httprelay");
const types = @import("../../agent/types.zig");
const std = @import("std");
const RouteMatch = httprelay.RouteMatch;

pub const ApiDialect = types.ApiDialect;

/// Routes that carry Anthropic Messages inference.
pub const anthropic_inference = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/messages"} }};

/// Routes that carry OpenAI Responses inference.
pub const openai_inference = [_]RouteMatch{.{ .method = "POST", .paths = &.{ "/v1/responses", "/backend-api/codex/responses" } }};

/// The routes a tunnel to `dialect` watches as inference; every other
/// request is auxiliary.
///
/// ```zig
/// const watched = request_support.inferenceRoutes(exchange.dialect);
/// ```
pub fn inferenceRoutes(dialect: types.ApiDialect) []const RouteMatch {
    return switch (dialect) {
        .anthropic_messages => &anthropic_inference,
        .openai_responses => &openai_inference,
        .unknown => &.{},
    };
}

pub const RequestClass = enum {
    inference,
    auxiliary,
};

/// Whether a request of this method and target is inference for `dialect`.
fn isInference(dialect: types.ApiDialect, method: []const u8, target: []const u8) bool {
    return RouteMatch.matchesAny(method, target, inferenceRoutes(dialect));
}

test "request classification enforces dialect route ownership" {
    try std.testing.expect(isInference(.anthropic_messages, "POST", "/v1/messages?beta=true"));
    try std.testing.expect(isInference(.openai_responses, "post", "/v1/responses"));
    try std.testing.expect(isInference(.openai_responses, "POST", "/backend-api/codex/responses?stream=true"));

    try std.testing.expect(!isInference(.anthropic_messages, "POST", "/v1/responses"));
    try std.testing.expect(!isInference(.openai_responses, "POST", "/v1/messages"));
    try std.testing.expect(!isInference(.unknown, "POST", "/v1/messages"));
}

test "request classification rejects non-generation variants" {
    inline for (.{
        .{ "GET", "/v1/messages" },
        .{ "POST", "/v1/messages/count_tokens?beta=true" },
        .{ "POST", "/api/event_logging/v2/batch" },
        .{ "POST", "/V1/MESSAGES" },
        .{ "POST", "/v1/messages#fragment" },
    }) |request| {
        try std.testing.expect(!isInference(.anthropic_messages, request[0], request[1]));
    }
}
