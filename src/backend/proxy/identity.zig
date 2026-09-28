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

    var secret: Secret = undefined;
    defer std.crypto.secureZero(u8, &secret);
    _ = std.fmt.hexToBytes(&secret, value["telar:".len..]) catch return null;
    return secret;
}

test "proxy basic authentication round trips the secret" {
    const secret: Secret = .{0x5a} ** secret_bytes;
    var url_buffer: [256]u8 = undefined;
    const url = try formatUrl(&url_buffer, 45100, &secret);
    try std.testing.expectEqualStrings("http://telar:" ++ "5a" ** secret_bytes ++ "@127.0.0.1:45100", url);
    const raw = "telar:" ++ "5a" ** secret_bytes;
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var head_buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{basic});
    var parsed = parseProxyAuthorization(head).?;
    defer std.crypto.secureZero(u8, &parsed);
    try std.testing.expect(sameSecret(&parsed, &secret));
    try std.testing.expect(!sameSecret(&parsed, &(.{0x5b} ** secret_bytes)));
}

fn expectRejectedUserInfo(raw: []const u8) !void {
    var encoded: [256]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var head_buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "CONNECT a:1 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{basic});
    try std.testing.expect(parseProxyAuthorization(head) == null);
}

test "proxy basic authentication rejects malformed, duplicate and foreign userinfo" {
    try expectRejectedUserInfo("telar:5a5a");
    try expectRejectedUserInfo("user:" ++ "5a" ** secret_bytes);
    try expectRejectedUserInfo("telar:" ++ "5a" ** secret_bytes ++ "a");
    try expectRejectedUserInfo("telar:" ++ "zz" ** secret_bytes);
    try std.testing.expect(parseProxyAuthorization("CONNECT a:1 HTTP/1.1\r\n\r\n") == null);
    try std.testing.expect(parseProxyAuthorization("CONNECT a:1 HTTP/1.1\r\nProxy-Authorization: Bearer x\r\n\r\n") == null);

    const valid_raw = "telar:" ++ "5a" ** secret_bytes;
    var valid_storage: [std.base64.standard.Encoder.calcSize(valid_raw.len)]u8 = undefined;
    const valid = std.base64.standard.Encoder.encode(&valid_storage, valid_raw);
    var duplicate_buf: [512]u8 = undefined;
    const duplicate = try std.fmt.bufPrint(&duplicate_buf, "CONNECT a:1 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{ valid, valid });
    try std.testing.expect(parseProxyAuthorization(duplicate) == null);
}
