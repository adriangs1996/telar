//! The link a notification may carry (docs/notifications.md): an https URL
//! whose host is written plainly, so the host a card shows is the host a
//! click opens. No user info (`https://claude.ai@evil.example/` opens
//! evil.example), no percent-encoding, backslash or port in the authority,
//! printable ASCII without spaces, at most `max_notification_link_bytes`.
const std = @import("std");
const types = @import("types.zig");

const scheme = "https://";

/// Refuses a link a card could not show honestly; an empty link is none.
///
/// ```zig
/// try notification_link.validate("https://auth.openai.com/codex/device");
/// ```
pub fn validate(link: []const u8) !void {
    if (link.len == 0) {
        return;
    }

    if (link.len > types.max_notification_link_bytes or !std.mem.startsWith(u8, link, scheme)) {
        return error.InvalidNotificationLink;
    }

    for (link) |byte| {
        if (byte <= ' ' or byte >= 0x7f or byte == '\\') {
            return error.InvalidNotificationLink;
        }
    }

    const authority = host(link);
    if (authority.len == 0 or authority[0] == '.' or authority[0] == '-' or authority[authority.len - 1] == '.') {
        return error.InvalidNotificationLink;
    }

    for (authority) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') {
            return error.InvalidNotificationLink;
        }
    }
}

/// The host of a link `validate` accepted: what follows `https://` up to
/// its path, query or fragment.
///
/// ```zig
/// const shown = notification_link.host(item.link());  // "auth.openai.com"
/// ```
pub fn host(link: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, link, scheme)) {
        return "";
    }

    const rest = link[scheme.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

test "a link's host is what a click opens" {
    try validate("https://auth.openai.com/codex/device");
    try validate("https://claude.com/cai/oauth/authorize?code=true&x=a@b");
    try validate("");
    try std.testing.expectEqualStrings("auth.openai.com", host("https://auth.openai.com/codex/device"));
    try std.testing.expectEqualStrings("claude.com", host("https://claude.com?x=1"));

    for ([_][]const u8{
        "http://example.com",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https://",
        "https:///path",
        "https://claude.ai@evil.example/",
        "https://claude.ai:443@evil.example/",
        "https://evil.example\\@claude.ai/",
        "https://claude%2Eai/",
        "https://claude.ai:8443/",
        "https://[::1]/",
        "https://.claude.ai/",
        "https://example.com/a b",
        "https://example.com/\x1b",
    }) |link| {
        try std.testing.expectError(error.InvalidNotificationLink, validate(link));
    }
}
