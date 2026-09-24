//! HTTP negotiation required to observe Claude's streaming protocol.

const httprelay = @import("httprelay");
const std = @import("std");
const Headers = httprelay.Headers;
const Rewrite = httprelay.Rewrite;
const rewrites = httprelay.rewrites;
const request_support = @import("request_support.zig");
const types = @import("../../agent/types.zig");
const header_rules = httprelay.header_rules;

/// Asks Claude inference routes for identity-encoded SSE, so the proxy can
/// read the stream it forwards. Auxiliary routes, responses and other
/// providers keep their headers.
const identity_encoding = [_]Rewrite{.{
    .direction = .request,
    .kind = .request,
    .route = request_support.anthropic_inference[0],
    .effects = &.{.{ .set = .{ .name = "accept-encoding", .value = "identity", .sensitive = false } }},
}};

/// The request rewrites a tunnel to `dialect` hands its relay.
///
/// ```zig
/// const request_rewrites = claude_transport.requestRewrites(exchange.dialect);
/// ```
pub fn requestRewrites(dialect: types.ApiDialect) []const Rewrite {
    return switch (dialect) {
        .anthropic_messages => &identity_encoding,
        .openai_responses, .unknown => &.{},
    };
}

fn rewritten(case: RewriteCase) !Headers {
    var headers: Headers = .{};
    try headers.append(.{ .name = ":method", .value = case.method });
    try headers.append(.{ .name = ":path", .value = case.target });
    if (case.encoding) |encoding| {
        try headers.append(.{ .name = "accept-encoding", .value = encoding });
    }

    _ = rewrites.apply(requestRewrites(case.dialect), .{ .direction = case.direction, .kind = case.kind }, &headers);
    return headers;
}

test "Claude inference requests negotiate identity encoding" {
    inline for (.{
        RewriteCase{},
        RewriteCase{ .target = "/v1/messages?beta=true" },
        RewriteCase{ .encoding = null },
    }) |case| {
        const headers = try rewritten(case);
        try std.testing.expectEqualStrings("identity", headers.find("accept-encoding").?);
    }
}

test "Claude identity negotiation preserves unrelated traffic" {
    inline for (.{
        RewriteCase{ .dialect = .openai_responses },
        RewriteCase{ .direction = .response },
        RewriteCase{ .kind = .trailers },
        RewriteCase{ .method = "GET" },
        RewriteCase{ .target = "/v1/messages/count_tokens" },
        RewriteCase{ .target = "/api/event_logging/v2/batch" },
    }) |case| {
        const headers = try rewritten(case);
        try std.testing.expectEqualStrings("gzip, br", headers.find("accept-encoding").?);
    }
}

const RewriteCase = struct {
    dialect: types.ApiDialect = .anthropic_messages,
    direction: header_rules.Direction = .request,
    kind: header_rules.HeaderKind = .request,
    method: []const u8 = "POST",
    target: []const u8 = "/v1/messages",
    encoding: ?[]const u8 = "gzip, br",
};
