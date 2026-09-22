//! Builds bounded directory-listing queries from expanded prompt paths.

const path_expansion = @import("../../completion/path_expansion.zig");

pub const max_path_bytes = path_expansion.max_path_bytes;

pub const DirectoryStatus = enum { directory, missing, other };

/// Appends a separator in the caller buffer when the prompt requests children.
/// Example: `const query = path_completions.listingQuery(text, expanded, &buffer);`
pub fn listingQuery(text: []const u8, expanded: []const u8, buffer: *[max_path_bytes]u8) []const u8 {
    const children = text.len == 0 or path_expansion.endsWithSeparator(text);
    if (!children or expanded.len == 0 or expanded[expanded.len - 1] == '/' or expanded.len + 1 > max_path_bytes) {
        return expanded;
    }

    buffer[expanded.len] = '/';
    return buffer[0 .. expanded.len + 1];
}
