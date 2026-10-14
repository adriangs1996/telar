//! One grapheme no resident face covers, waiting for an installed-font
//! lookup off the render thread. It owns copies of both the grapheme, which
//! names its miss, and the significant codepoints the platform is asked for.
const std = @import("std");
const FontQuery = @This();

/// The longest UTF-8 grapheme a lookup queries, after dropping joiners
/// and selectors; longer clusters keep the replacement glyph.
pub const max_bytes = 64;

/// The font set that asked; a result for a set rebuilt since is dropped.
set_identity: u64,
// SAFETY: init copies the grapheme before recording text_len; text() exposes only that prefix.
text_bytes: [max_bytes]u8 = undefined,
text_len: u8 = 0,
// SAFETY: init copies the significant codepoints and their terminator before recording query_len.
query_bytes: [max_bytes:0]u8 = undefined,
query_len: u8 = 0,

/// Null when either the grapheme or its significant codepoints do not fit.
/// Example: `const query = FontQuery.init(set.identity, text, significant) orelse return;`
pub fn init(set_identity: u64, grapheme: []const u8, significant: []const u8) ?FontQuery {
    if (grapheme.len > max_bytes or significant.len > max_bytes) {
        return null;
    }

    var query: FontQuery = .{ .set_identity = set_identity };
    @memcpy(query.text_bytes[0..grapheme.len], grapheme);
    query.text_len = @intCast(grapheme.len);
    @memcpy(query.query_bytes[0..significant.len], significant);
    query.query_bytes[significant.len] = 0;
    query.query_len = @intCast(significant.len);
    return query;
}

pub fn text(self: *const FontQuery) []const u8 {
    return self.text_bytes[0..self.text_len];
}

/// The significant codepoints, NUL-terminated for the native port.
/// Example: `lookup(query.codepoints().ptr, &match)`
pub fn codepoints(self: *const FontQuery) [:0]const u8 {
    return self.query_bytes[0..self.query_len :0];
}

/// Example: `if (query.names(text)) return;`
pub fn names(self: *const FontQuery, grapheme: []const u8) bool {
    return std.mem.eql(u8, self.text(), grapheme);
}
