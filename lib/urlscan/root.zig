//! Recognition of URI text: classifying a complete URI by scheme and
//! finding the URI under a byte offset in one line, without the delimiters
//! and unmatched punctuation around it. Where the text came from and what
//! opens a link are the caller's.

const uri = @import("uri.zig");

pub const Match = @import("Match.zig");
pub const Scheme = uri.Scheme;
pub const max_uri_bytes = uri.max_uri_bytes;
pub const classify = uri.classify;
pub const extractAt = uri.extractAt;

test {
    _ = @import("Match.zig");
    _ = @import("Prefix.zig");
    _ = @import("uri.zig");
}
