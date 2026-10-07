//! The open pick list's options that match the palette query, best first.
const PickItems = @import("../bars/PickItems.zig");
const PickMatch = @import("PickMatch.zig");
const PickResults = @This();

// SAFETY: pick_list writes each match before increasing len; sorting and slice read only that initialized prefix.
matches: [PickItems.max_items]PickMatch = undefined,
len: u16 = 0,

/// Example: `for (results.slice()) |match| draw(items.label(match.index));`
pub fn slice(self: *const PickResults) []const PickMatch {
    return self.matches[0..self.len];
}
