//! Authentication and target policy for one HTTP CONNECT request.

const core = @import("telar-core");
const identity = @import("identity.zig");
const Policy = @import("Policy.zig");
const std = @import("std");

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
    /// No credential, admitted because `anonymous_tunnels` is on and the
    /// proxy does not intercept the target.
    anonymous: Target,
    rejected: Rejection,
};

/// Authenticates before revealing target validity. Only an exact
/// `CONNECT authority HTTP/1.1` line with a bounded hostname and a nonzero
/// decimal port is accepted. With `anonymous_tunnels`, a request without any
/// `Proxy-Authorization` field opens an opaque tunnel to a host outside
/// `intercept_hosts`; a host the proxy intercepts, or a malformed or wrong
/// credential, is still refused. The presented secret never outlives this
/// call; the validated hostname borrows from `head`.
///
/// ```zig
/// const decision = connect_authentication.authenticate(&secret, false, &policy, head);
/// ```
pub fn authenticate(secret: *const identity.Secret, anonymous_tunnels: bool, intercept_hosts: *const Policy, head: []const u8) Decision {
    if (anonymous_tunnels and !identity.hasProxyAuthorization(head)) {
        const target = parseTarget(head) orelse return rejectInvalidTarget();
        if (intercept_hosts.contains(target.host.bytes)) {
            return rejectInvalidAuthorization();
        }

        return .{ .anonymous = target };
    }

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
