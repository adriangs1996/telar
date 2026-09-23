const link = @import("link.zig");
const Match = @This();

scheme: link.Scheme,
start: usize,
end: usize,

/// Returns the matched URI from the source passed to `extractAt`.
///
/// ```zig
/// const uri = match.text(line);
/// ```
pub fn text(self: Match, source: []const u8) []const u8 {
    return source[self.start..self.end];
}
