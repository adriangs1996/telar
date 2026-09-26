//! Recognition of URI text: classifying a complete URI by scheme, finding
//! the URI under a byte offset in one line, without the delimiters and
//! unmatched punctuation around it, and finding the inline Markdown link
//! around an offset. Where the text came from and what opens a link are the
//! caller's.

const uri = @import("uri.zig");
const markdown = @import("markdown.zig");

pub const Match = @import("Match.zig");
pub const MarkdownLink = @import("MarkdownLink.zig");
pub const Scheme = uri.Scheme;
pub const max_uri_bytes = uri.max_uri_bytes;
pub const max_label_bytes = markdown.max_label_bytes;
pub const classify = uri.classify;
pub const extractAt = uri.extractAt;
pub const markdownLinkAt = markdown.linkAt;

test {
    _ = @import("Match.zig");
    _ = @import("MarkdownLink.zig");
    _ = @import("Prefix.zig");
    _ = @import("markdown.zig");
    _ = @import("uri.zig");
}
