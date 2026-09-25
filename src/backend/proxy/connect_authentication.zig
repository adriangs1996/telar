//! Authentication and target policy for one HTTP CONNECT request.

const core = @import("telar-core");
const identity = @import("identity.zig");
const Registry = @import("Registry.zig");
const std = @import("std");
const Credential = @import("Credential.zig");
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

pub const Authenticated = @import("Authenticated.zig");

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
    authenticated: Authenticated,
    rejected: Rejection,
};

/// Authenticates before revealing target validity. Only an exact
/// `CONNECT authority HTTP/1.1` line with a bounded hostname and a nonzero
/// decimal port is accepted. A successful value names the credential by its
/// non-secret identity, so the token never outlives this call; its validated
/// hostname borrows from `head`.
///
/// ```zig
/// const decision = connect_authentication.authenticate(io, &registry, head);
/// ```
pub fn authenticate(io: std.Io, credentials: *Registry, head: []const u8) Decision {
    var credential = identity.parseProxyAuthorization(head) orelse return rejectInvalidAuthorization();
    defer std.crypto.secureZero(u8, &credential.token);

    const owner = credentials.identify(io, &credential) orelse return rejectUnknownCredential();
    const target = parseTarget(head) orelse return rejectInvalidTarget();
    return .{ .authenticated = .{
        .owner = owner,
        .target = target,
    } };
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

/// A registry holding `testCredential` when `live`.
fn testRegistry(live: bool) !Registry {
    var registry: Registry = .{};
    if (live) {
        try registry.register(std.testing.io, &testCredential());
    }

    return registry;
}

fn execute(registry: *Registry, head: []const u8) Decision {
    return authenticate(std.testing.io, registry, head);
}

fn testCredential() Credential {
    return .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 12,
        .token = .{
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        },
    };
}

fn requestHead(start_line: []const u8, output: []u8) ![]const u8 {
    const raw = "telar:7.12.00112233445566778899aabbccddeeff";
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

test "missing authorization is rejected before credential or target lookup" {
    var registry = try testRegistry(true);

    try expectRejected(
        execute(&registry, "GET / HTTP/1.1\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
}

test "a malformed Basic value is an invalid authorization" {
    var registry = try testRegistry(true);

    try expectRejected(
        execute(&registry, "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic !!!\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
}

test "a parsed credential must still be live" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);
    var registry = try testRegistry(false);

    try expectRejected(
        execute(&registry, head),
        .{
            .reason = .unknown_credential,
            .response = authentication_required_response,
            .metric = .unknown_credential,
        },
    );
}

test "target validity is hidden until credential authentication succeeds" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("GET / HTTP/1.1", &head_buffer);
    var registry = try testRegistry(false);

    try expectRejected(
        execute(&registry, head),
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
        var registry = try testRegistry(true);

        try expectRejected(
            execute(&registry, head),
            .{
                .reason = .invalid_target,
                .response = bad_request_response,
                .metric = null,
            },
        );
    }
}

test "a live credential and valid CONNECT target produce authenticated input" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);
    var registry = try testRegistry(true);

    const authenticated = switch (execute(&registry, head)) {
        .authenticated => |value| value,
        .rejected => return error.ExpectedAuthenticatedConnect,
    };

    try std.testing.expectEqualDeep(registry.identify(std.testing.io, &testCredential()).?, authenticated.owner);
    try std.testing.expectEqualStrings("api.openai.com", authenticated.target.host.bytes);
    try std.testing.expectEqual(@as(u16, 443), authenticated.target.port);
}
