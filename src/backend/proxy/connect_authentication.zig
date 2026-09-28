//! Authentication and target policy for one HTTP CONNECT request.

const core = @import("telar-core");
const identity = @import("identity.zig");
const std = @import("std");
const ExpectedRejection = @import("ExpectedRejection.zig");

const authentication_required_response =
    "HTTP/1.1 407 Proxy Authentication Required\r\n" ++
    "Proxy-Authenticate: Basic realm=\"telar\"\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n\r\n";

const bad_request_response =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "Content-Length: 0\r\n\r\n";

pub const Target = @import("Target.zig");

pub const RejectionMetric = enum {
    invalid_authorization,
    unknown_credential,
};

pub const RejectionReason = enum {
    invalid_authorization,
    unknown_credential,
    invalid_target,
};

pub const Rejection = @import("Rejection.zig");

pub const Decision = union(enum) {
    authenticated: Target,
    rejected: Rejection,
};

/// Authenticates before revealing target validity. Only an exact
/// `CONNECT authority HTTP/1.1` line with a bounded hostname and a nonzero
/// decimal port is accepted. The presented secret never outlives this
/// call; the validated hostname borrows from `head`.
///
/// ```zig
/// const decision = connect_authentication.authenticate(&secret, head);
/// ```
pub fn authenticate(secret: *const identity.Secret, head: []const u8) Decision {
    var presented = identity.parseProxyAuthorization(head) orelse return rejectInvalidAuthorization();
    defer std.crypto.secureZero(u8, &presented);

    if (!identity.sameSecret(&presented, secret)) {
        return rejectUnknownCredential();
    }

    const target = parseTarget(head) orelse return rejectInvalidTarget();
    return .{ .authenticated = target };
}

pub fn parseTarget(head: []const u8) ?Target {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    if (!std.mem.eql(u8, parts.next() orelse return null, "CONNECT")) {
        return null;
    }

    const authority = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "HTTP/1.1") or parts.next() != null) {
        return null;
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
    if (colon == 0) {
        return null;
    }

    const host_bytes = authority[0..colon];
    if (host_bytes.len > core.max_hostname_bytes) {
        return null;
    }

    const host = std.Io.net.HostName.init(host_bytes) catch return null;
    const port_text = authority[colon + 1 ..];
    if (port_text.len == 0) {
        return null;
    }

    for (port_text) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return null;
        }
    }

    const port = std.fmt.parseInt(u16, port_text, 10) catch return null;
    if (port == 0) {
        return null;
    }

    return .{ .host = host, .port = port };
}

pub fn rejectInvalidAuthorization() Decision {
    return .{ .rejected = .{
        .reason = .invalid_authorization,
        .response = authentication_required_response,
        .metric = .invalid_authorization,
    } };
}

pub fn rejectUnknownCredential() Decision {
    return .{ .rejected = .{
        .reason = .unknown_credential,
        .response = authentication_required_response,
        .metric = .unknown_credential,
    } };
}

pub fn rejectInvalidTarget() Decision {
    return .{ .rejected = .{
        .reason = .invalid_target,
        .response = bad_request_response,
        .metric = null,
    } };
}

const test_secret: identity.Secret = .{0x5a} ** identity.secret_bytes;

fn requestHead(start_line: []const u8, output: []u8) ![]const u8 {
    const raw = "telar:" ++ "5a" ** identity.secret_bytes;
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    return std.fmt.bufPrint(output, "{s}\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{ start_line, basic });
}

fn expectRejected(decision: Decision, expected: ExpectedRejection) !void {
    const rejection = switch (decision) {
        .authenticated => return error.ExpectedConnectRejection,
        .rejected => |value| value,
    };
    try std.testing.expectEqual(expected.reason, rejection.reason);
    try std.testing.expectEqualStrings(expected.response, rejection.response);
    try std.testing.expectEqual(expected.metric, rejection.metric);
}

test "missing authorization is rejected before secret or target lookup" {
    try expectRejected(
        authenticate(&test_secret, "GET / HTTP/1.1\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
}

test "a malformed Basic value is an invalid authorization" {
    try expectRejected(
        authenticate(&test_secret, "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic !!!\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
}

test "a well-formed secret must match the proxy secret" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);
    const other: identity.Secret = .{0x5b} ** identity.secret_bytes;

    try expectRejected(
        authenticate(&other, head),
        .{
            .reason = .unknown_credential,
            .response = authentication_required_response,
            .metric = .unknown_credential,
        },
    );
}

test "target validity is hidden until authentication succeeds" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("GET / HTTP/1.1", &head_buffer);
    const other: identity.Secret = .{0x5b} ** identity.secret_bytes;

    try expectRejected(
        authenticate(&other, head),
        .{
            .reason = .unknown_credential,
            .response = authentication_required_response,
            .metric = .unknown_credential,
        },
    );
}

test "authenticated malformed targets map to a bad request without an auth metric" {
    const invalid_start_lines = [_][]const u8{
        "GET api.openai.com:443 HTTP/1.1",
        "CONNECT api.openai.com:443",
        "CONNECT api.openai.com:443 HTTP/1.0",
        "CONNECT api.openai.com:443 HTTP/1.1 extra",
        "CONNECT :443 HTTP/1.1",
        "CONNECT bad_host:443 HTTP/1.1",
        "CONNECT api.openai.com:0 HTTP/1.1",
        "CONNECT api.openai.com:+443 HTTP/1.1",
        "CONNECT api.openai.com:65536 HTTP/1.1",
        "CONNECT " ++ "a" ** (core.max_hostname_bytes + 1) ++ ":443 HTTP/1.1",
    };

    for (invalid_start_lines) |start_line| {
        var head_buffer: [512]u8 = undefined;
        const head = try requestHead(start_line, &head_buffer);

        try expectRejected(
            authenticate(&test_secret, head),
            .{
                .reason = .invalid_target,
                .response = bad_request_response,
                .metric = null,
            },
        );
    }
}

test "the proxy secret and a valid CONNECT target produce an authenticated target" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);

    const target = switch (authenticate(&test_secret, head)) {
        .authenticated => |value| value,
        .rejected => return error.ExpectedAuthenticatedConnect,
    };

    try std.testing.expectEqualStrings("api.openai.com", target.host.bytes);
    try std.testing.expectEqual(@as(u16, 443), target.port);
}
