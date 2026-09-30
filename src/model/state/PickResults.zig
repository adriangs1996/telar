//! The open pick list's options that match the palette query, best first.
const PickItems = @import("../bars/PickItems.zig");
const PickMatch = @import("PickMatch.zig");
const PickResults = @This();

matches: [PickItems.max_items]PickMatch = undefined,
len: u16 = 0,

/// Example: `for (results.slice()) |match| draw(items.label(match.index));`
pub fn slice(self: *const PickResults) []const PickMatch {
    return self.matches[0..self.len];
}
