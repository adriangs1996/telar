//! Provider ownership and request classification.

const std = @import("std");
const core = @import("telar-core");

pub const AgentProvider = core.schema.AgentProvider;

pub const Request = struct {
    method: []const u8,
    target: []const u8,
};

pub const RequestClass = enum {
    inference,
    auxiliary,
};

/// Identifies the provider that owns an authenticated CONNECT target.
/// Matching is ASCII case-insensitive and requires a DNS label boundary.
///
/// ```zig
/// const provider = identify("api.anthropic.com");
/// ```
pub fn identify(host: []const u8) AgentProvider {
    if (hostMatches(host, "anthropic.com")) {
        return .claude;
    }

    if (hostMatches(host, "openai.com") or hostMatches(host, "chatgpt.com")) {
        return .codex;
    }

    return .unknown;
}

/// Classifies a request route for `provider`. For Claude, `.inference` is a
/// candidate which the request-body observer must refine before publication.
/// Query parameters do not change route ownership. Unknown providers and
/// cross-provider routes are always auxiliary.
///
/// ```zig
/// const class = classify(.claude, .{ .method = "POST", .target = "/v1/messages" });
/// ```
pub fn classify(provider: AgentProvider, request: Request) RequestClass {
    if (!std.ascii.eqlIgnoreCase(request.method, "POST")) {
        return .auxiliary;
    }

    const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
    const inference = switch (provider) {
        .claude => std.mem.eql(u8, path, "/v1/messages"),
        .codex => std.mem.eql(u8, path, "/v1/responses") or
            std.mem.eql(u8, path, "/backend-api/codex/responses"),
        .unknown => false,
    };

    return if (inference) .inference else .auxiliary;
}

fn hostMatches(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) {
        return true;
    }

    if (host.len <= domain.len or host[host.len - domain.len - 1] != '.') {
        return false;
    }

    return std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain);
}

test "provider identification requires a DNS label boundary" {
    try std.testing.expectEqual(AgentProvider.claude, identify("anthropic.com"));
    try std.testing.expectEqual(AgentProvider.claude, identify("API.ANTHROPIC.COM"));
    try std.testing.expectEqual(AgentProvider.codex, identify("api.openai.com"));
    try std.testing.expectEqual(AgentProvider.codex, identify("ab.chatgpt.com"));

    inline for (.{
        "",
        "evil-anthropic.com",
        "anthropic.com.evil.test",
        "evilopenai.com",
        "chatgpt.com.evil.test",
    }) |host| {
        try std.testing.expectEqual(AgentProvider.unknown, identify(host));
    }
}

test "request classification enforces provider route ownership" {
    try std.testing.expectEqual(RequestClass.inference, classify(.claude, .{
        .method = "POST",
        .target = "/v1/messages?beta=true",
    }));
    try std.testing.expectEqual(RequestClass.inference, classify(.codex, .{
        .method = "post",
        .target = "/v1/responses",
    }));
    try std.testing.expectEqual(RequestClass.inference, classify(.codex, .{
        .method = "POST",
        .target = "/backend-api/codex/responses?stream=true",
    }));

    try std.testing.expectEqual(RequestClass.auxiliary, classify(.claude, .{
        .method = "POST",
        .target = "/v1/responses",
    }));
    try std.testing.expectEqual(RequestClass.auxiliary, classify(.codex, .{
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
        try std.testing.expectEqual(RequestClass.auxiliary, classify(.claude, request));
    }
}
