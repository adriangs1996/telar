//! The proxy secret carried in standard proxy URL userinfo. One secret per
//! proxy directory admits every child the runtime launches; it proves the
//! caller inherited Telar's environment, nothing more.

const std = @import("std");

pub const secret_bytes = 32;
pub const Secret = [secret_bytes]u8;
/// Basic userinfo: `telar:` and the hex secret.
pub const userinfo_bytes = "telar:".len + secret_bytes * 2;

/// Generates one cryptographically random secret.
///
/// ```zig
/// var secret = randomSecret(io);
/// defer std.crypto.secureZero(u8, &secret);
/// ```
pub fn randomSecret(io: std.Io) Secret {
    // SAFETY: The random source fills every byte of secret before return.
    var secret: Secret = undefined;
    const source: std.Random.IoSource = .{ .io = io };
    source.interface().bytes(&secret);
    return secret;
}

/// Formats the loopback proxy URL carrying the secret.
///
/// ```zig
/// const url = try formatUrl(&buffer, 45100, &secret);
/// ```
pub fn formatUrl(buffer: []u8, port: u16, secret: *const Secret) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://telar:{x}@127.0.0.1:{d}", .{ secret.*, port });
}

/// Parses exactly one Basic `Proxy-Authorization` secret. Missing,
/// malformed, oversized, or duplicate fields return `null`.
///
/// ```zig
/// var secret = parseProxyAuthorization(head) orelse return error.Unauthorized;
/// defer std.crypto.secureZero(u8, &secret);
/// ```
pub fn parseProxyAuthorization(head: []const u8) ?Secret {
    var secret: ?Secret = null;
    defer {
        if (secret) |*value| {
            std.crypto.secureZero(u8, value);
        }
    }

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        if (!std.ascii.eqlIgnoreCase(line[0..colon], "proxy-authorization")) {
            continue;
        }

        if (secret != null) {
            return null;
        }

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (value.len < 7 or !std.ascii.eqlIgnoreCase(value[0..5], "basic") or
            value[5] != ' ')
        {
            return null;
        }

        const encoded = std.mem.trim(u8, value[6..], " \t");
        var decoded: [192]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;

        if (decoded_len > decoded.len) {
            return null;
        }

        std.base64.standard.Decoder.decode(decoded[0..decoded_len], encoded) catch return null;
        defer std.crypto.secureZero(u8, decoded[0..decoded_len]);
        secret = parseUserInfo(decoded[0..decoded_len]) orelse return null;
    }

    return secret;
}

/// Whether `head` carries any `Proxy-Authorization` field, valid or not.
///
/// ```zig
/// if (!hasProxyAuthorization(head)) return admitAnonymous(head);
/// ```
pub fn hasProxyAuthorization(head: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "proxy-authorization")) {
            return true;
        }
    }

    return false;
}

/// Compares two secrets in constant time.
///
/// ```zig
/// if (!sameSecret(&presented, &expected)) return rejectUnknownCredential();
/// ```
pub fn sameSecret(left: *const Secret, right: *const Secret) bool {
    return std.crypto.timing_safe.eql(Secret, left.*, right.*);
}

fn parseUserInfo(value: []const u8) ?Secret {
    if (value.len != userinfo_bytes or !std.mem.startsWith(u8, value, "telar:")) {
        return null;
    }

    // SAFETY: The userinfo length check requires exactly two hex characters per secret byte; hexToBytes must succeed before return.
    var secret: Secret = undefined;
    defer std.crypto.secureZero(u8, &secret);
    _ = std.fmt.hexToBytes(&secret, value["telar:".len..]) catch return null;
    return secret;
}
