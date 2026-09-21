const std = @import("std");
const GenericField = @import("../../input/GenericField.zig").Type;
const SearchMatch = @import("SearchMatch.zig");
const limits = @import("limits.zig");
const Search = @This();

pub const Direction = enum { forward, backward };

query: GenericField(limits.search_bytes) = .{},
match: ?SearchMatch = null,

/// Retains a bounded literal query; invalid input leaves the previous search intact.
/// Example: `_ = search.setQuery("café");`
pub fn setQuery(self: *Search, query: []const u8) bool {
    if (query.len > limits.search_bytes or !std.unicode.utf8ValidateSlice(query) or std.mem.indexOfAny(u8, query, "\x00\r\n") != null) {
        return false;
    }

    _ = self.query.replace(.{ 0, @intCast(self.query.len) }, query);
    self.match = null;
    return true;
}
