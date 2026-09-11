const Match = @This();
const source_namespace = @import("link.zig");
scheme: source_namespace.Scheme,
start: usize,
end: usize,

/// Returns the matched URI from the source passed to `extractAt`.
///
/// ```zig
/// const uri = match.text(line);
/// ```
pub fn text(match: Match, source: []const u8) []const u8 {
    return source[match.start..match.end];
}
