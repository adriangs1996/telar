//! Authentication and target policy for one HTTP CONNECT request.

const TargetType = @import("Target.zig");
const AuthenticatedType = @import("Authenticated.zig");
const RejectionType = @import("Rejection.zig");
const GenericCredentialPort = @import("GenericCredentialPort.zig").Type;
const GenericConnectAuthenticationCommand = @import("GenericConnectAuthenticationCommand.zig").Type;
const std = @import("std");
const max_hostname_bytes_module = @import("telar-core").max_hostname_bytes;
const TestStore = @import("TestStore.zig");
const CredentialType = @import("Credential.zig");
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
    authenticated: AuthenticatedType,
    rejected: RejectionType,
};

pub fn parseTarget(head: []const u8) ?TargetType {
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
    if (host_bytes.len > max_hostname_bytes_module) {
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

const test_credential_port: GenericCredentialPort(TestStore) = .{
    .contains = TestStore.contains,
};

const TestCommand = GenericConnectAuthenticationCommand(TestStore, test_credential_port);

fn testCredential() CredentialType {
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
    var store: TestStore = .{ .expected = testCredential() };

    try expectRejected(
        TestCommand.execute(&store, "GET / HTTP/1.1\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
    try std.testing.expectEqual(@as(usize, 0), store.lookups);
}

test "a malformed Basic value is an invalid authorization" {
    var store: TestStore = .{ .expected = testCredential() };

    try expectRejected(
        TestCommand.execute(&store, "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic !!!\r\n\r\n"),
        .{
            .reason = .invalid_authorization,
            .response = authentication_required_response,
            .metric = .invalid_authorization,
        },
    );
    try std.testing.expectEqual(@as(usize, 0), store.lookups);
}

test "a parsed credential must still be live" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);
    var store: TestStore = .{ .expected = testCredential(), .live = false };

    try expectRejected(
        TestCommand.execute(&store, head),
        .{
            .reason = .unknown_credential,
            .response = authentication_required_response,
            .metric = .unknown_credential,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), store.lookups);
}

test "target validity is hidden until credential authentication succeeds" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("GET / HTTP/1.1", &head_buffer);
    var store: TestStore = .{ .expected = testCredential(), .live = false };

    try expectRejected(
        TestCommand.execute(&store, head),
        .{
            .reason = .unknown_credential,
            .response = authentication_required_response,
            .metric = .unknown_credential,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), store.lookups);
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
        "CONNECT " ++ "a" ** (max_hostname_bytes_module + 1) ++ ":443 HTTP/1.1",
    };

    for (invalid_start_lines) |start_line| {
        var head_buffer: [512]u8 = undefined;
        const head = try requestHead(start_line, &head_buffer);
        var store: TestStore = .{ .expected = testCredential() };

        try expectRejected(
            TestCommand.execute(&store, head),
            .{
                .reason = .invalid_target,
                .response = bad_request_response,
                .metric = null,
            },
        );
        try std.testing.expectEqual(@as(usize, 1), store.lookups);
    }
}

test "a live credential and valid CONNECT target produce authenticated input" {
    var head_buffer: [256]u8 = undefined;
    const head = try requestHead("CONNECT api.openai.com:443 HTTP/1.1", &head_buffer);
    var store: TestStore = .{ .expected = testCredential() };

    var authenticated = switch (TestCommand.execute(&store, head)) {
        .authenticated => |value| value,
        .rejected => return error.ExpectedAuthenticatedConnect,
    };
    defer std.crypto.secureZero(u8, &authenticated.credential.token);

    try std.testing.expect(std.meta.eql(testCredential(), authenticated.credential));
    try std.testing.expectEqualStrings("api.openai.com", authenticated.target.host.bytes);
    try std.testing.expectEqual(@as(u16, 443), authenticated.target.port);
    try std.testing.expectEqual(@as(usize, 1), store.lookups);
}
