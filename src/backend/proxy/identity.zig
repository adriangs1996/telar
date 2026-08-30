//! Per-pane proxy credentials carried in standard proxy URL userinfo.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const token_bytes = 16;
pub const Credential = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,
    token: [token_bytes]u8,
};

/// Generates one cryptographically random credential token.
///
/// ```zig
/// var token = randomToken(io);
/// defer std.crypto.secureZero(u8, &token);
/// ```
pub fn randomToken(io: std.Io) [token_bytes]u8 {
    var token: [token_bytes]u8 = undefined;
    const source: std.Random.IoSource = .{ .io = io };
    source.interface().bytes(&token);
    return token;
}

/// Formats the loopback proxy URL carrying one pane credential.
///
/// ```zig
/// const url = try formatUrl(&buffer, 45100, &credential);
/// ```
pub fn formatUrl(buffer: []u8, port: u16, credential: *const Credential) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://telar:{d}.{d}.{x}@127.0.0.1:{d}", .{
        schema.id.raw(credential.pane_id),
        credential.pane_generation,
        credential.token,
        port,
    });
}

/// Parses exactly one Basic `Proxy-Authorization` credential. Missing,
/// malformed, oversized, or duplicate fields return `null`.
///
/// ```zig
/// var credential = parseProxyAuthorization(head) orelse return error.Unauthorized;
/// defer std.crypto.secureZero(u8, &credential.token);
/// ```
pub fn parseProxyAuthorization(head: []const u8) ?Credential {
    var credential: ?Credential = null;
    defer {
        if (credential) |*value| {
            std.crypto.secureZero(u8, &value.token);
        }
    }

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        if (!std.ascii.eqlIgnoreCase(line[0..colon], "proxy-authorization")) {
            continue;
        }

        if (credential != null) {
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
        credential = parseUserInfo(decoded[0..decoded_len]) orelse return null;
    }

    return credential;
}

fn parseUserInfo(value: []const u8) ?Credential {
    if (!std.mem.startsWith(u8, value, "telar:")) {
        return null;
    }

    var parts = std.mem.splitScalar(u8, value["telar:".len..], '.');
    const pane_raw = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const generation = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const token_text = parts.next() orelse return null;

    if (parts.next() != null or generation == 0 or token_text.len != token_bytes * 2) {
        return null;
    }

    var token: [token_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &token);
    _ = std.fmt.hexToBytes(&token, token_text) catch return null;
    return .{
        .pane_id = schema.id.pane(pane_raw) catch return null,
        .pane_generation = generation,
        .token = token,
    };
}

test "proxy basic authentication round trips pane identity" {
    const raw = "telar:7.12.00112233445566778899aabbccddeeff";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var head_buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n", .{basic});
    var parsed = parseProxyAuthorization(head).?;
    defer std.crypto.secureZero(u8, &parsed.token);
    try std.testing.expectEqual(@as(u64, 7), schema.id.raw(parsed.pane_id));
    try std.testing.expectEqual(@as(u64, 12), parsed.pane_generation);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    }, &parsed.token);

    var url_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://telar:7.12.00112233445566778899aabbccddeeff@127.0.0.1:45100",
        try formatUrl(&url_buffer, 45100, &parsed),
    );
}

test "duplicate proxy authorization headers are rejected" {
    const raw = "telar:7.12.00112233445566778899aabbccddeeff";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var head_buffer: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buffer,
        "CONNECT api.openai.com:443 HTTP/1.1\r\n" ++
            "Proxy-Authorization: Basic {s}\r\n" ++
            "Proxy-Authorization: Basic {s}\r\n\r\n",
        .{ basic, basic },
    );

    try std.testing.expect(parseProxyAuthorization(head) == null);
}
