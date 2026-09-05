//! The API family one proxied exchange speaks.
//!
//! The proxy sees hosts, routes and streamed bodies. Those identify a wire
//! dialect, never the agent process behind the pane: Pi talks to Anthropic and
//! OpenAI from one process, and any agent may point at a compatible gateway.
//! Which agent owns an exchange is the runtime's decision, made from process
//! evidence first. The proxy only says what protocol it saw.

const std = @import("std");
pub const ApiDialect = @import("../../agent/root.zig").ApiDialect;

/// Identifies the dialect that owns an authenticated CONNECT target. Matching
/// is ASCII case-insensitive and requires a DNS label boundary.
///
/// ```zig
/// const dialect = identify("api.anthropic.com");
/// ```
pub fn identify(host: []const u8) ApiDialect {
    if (hostMatches(host, "anthropic.com")) {
        return .anthropic_messages;
    }

    if (hostMatches(host, "openai.com") or hostMatches(host, "chatgpt.com")) {
        return .openai_responses;
    }

    return .unknown;
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

test "dialect identification requires a DNS label boundary" {
    try std.testing.expectEqual(ApiDialect.anthropic_messages, identify("anthropic.com"));
    try std.testing.expectEqual(ApiDialect.anthropic_messages, identify("API.ANTHROPIC.COM"));
    try std.testing.expectEqual(ApiDialect.openai_responses, identify("api.openai.com"));
    try std.testing.expectEqual(ApiDialect.openai_responses, identify("ab.chatgpt.com"));

    inline for (.{
        "",
        "evil-anthropic.com",
        "anthropic.com.evil.test",
        "evilopenai.com",
        "chatgpt.com.evil.test",
    }) |host| {
        try std.testing.expectEqual(ApiDialect.unknown, identify(host));
    }
}
