//! Request classification by API dialect.

const std = @import("std");
const dialect_mod = @import("dialect.zig");

pub const ApiDialect = dialect_mod.ApiDialect;

pub const Request = struct {
    method: []const u8,
    target: []const u8,
};

pub const RequestClass = enum {
    inference,
    auxiliary,
};

/// Classifies a request route for `dialect`. For Anthropic Messages,
/// `.inference` is a candidate which the request-body observer must refine
/// before publication. Query parameters do not change route ownership.
/// Unknown dialects and cross-dialect routes are always auxiliary.
///
/// ```zig
/// const class = classify(.anthropic_messages, .{ .method = "POST", .target = "/v1/messages" });
/// ```
pub fn classify(dialect: ApiDialect, request: Request) RequestClass {
    if (!std.ascii.eqlIgnoreCase(request.method, "POST")) {
        return .auxiliary;
    }

    const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
    const inference = switch (dialect) {
        .anthropic_messages => std.mem.eql(u8, path, "/v1/messages"),
        .openai_responses => std.mem.eql(u8, path, "/v1/responses") or
            std.mem.eql(u8, path, "/backend-api/codex/responses"),
        .unknown => false,
    };

    return if (inference) .inference else .auxiliary;
}

test "request classification enforces dialect route ownership" {
    try std.testing.expectEqual(RequestClass.inference, classify(.anthropic_messages, .{
        .method = "POST",
        .target = "/v1/messages?beta=true",
    }));
    try std.testing.expectEqual(RequestClass.inference, classify(.openai_responses, .{
        .method = "post",
        .target = "/v1/responses",
    }));
    try std.testing.expectEqual(RequestClass.inference, classify(.openai_responses, .{
        .method = "POST",
        .target = "/backend-api/codex/responses?stream=true",
    }));

    try std.testing.expectEqual(RequestClass.auxiliary, classify(.anthropic_messages, .{
        .method = "POST",
        .target = "/v1/responses",
    }));
    try std.testing.expectEqual(RequestClass.auxiliary, classify(.openai_responses, .{
        .method = "POST",
        .target = "/v1/messages",
    }));
    try std.testing.expectEqual(RequestClass.auxiliary, classify(.unknown, .{
        .method = "POST",
        .target = "/v1/messages",
    }));
}

test "request classification rejects non-generation variants" {
    inline for (.{
        Request{ .method = "GET", .target = "/v1/messages" },
        Request{ .method = "POST", .target = "/v1/messages/count_tokens?beta=true" },
        Request{ .method = "POST", .target = "/api/event_logging/v2/batch" },
        Request{ .method = "POST", .target = "/V1/MESSAGES" },
        Request{ .method = "POST", .target = "/v1/messages#fragment" },
    }) |request| {
        try std.testing.expectEqual(RequestClass.auxiliary, classify(.anthropic_messages, request));
    }
}
