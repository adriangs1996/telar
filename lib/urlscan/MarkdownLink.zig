//! One inline Markdown link found by `markdown.linkAt`: the byte bounds of
//! the whole `[label](destination)` span and of its classified destination.
const uri = @import("uri.zig");
const MarkdownLink = @This();

scheme: uri.Scheme,
start: usize,
end: usize,
destination: [2]usize,

/// Returns the destination URI from the source passed to `linkAt`.
///
/// ```zig
/// const target = link.destinationText(line);
/// ```
pub fn destinationText(self: MarkdownLink, source: []const u8) []const u8 {
    return source[self.destination[0]..self.destination[1]];
}
