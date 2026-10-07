const goto_picker = @import("goto_picker.zig");
const Match = @import("Match.zig");
const Results = @This();

// SAFETY: goto_picker inserts matches into the initialized sorted prefix before increasing len; slice exposes only that prefix.
matches: [goto_picker.max_results]Match = undefined,
len: u8 = 0,

pub fn slice(self: *const Results) []const Match {
    return self.matches[0..self.len];
}
