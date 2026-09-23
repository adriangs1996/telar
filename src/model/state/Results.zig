const goto_picker = @import("goto_picker.zig");
const Match = @import("Match.zig");
const Results = @This();

matches: [goto_picker.max_results]Match = undefined,
len: u8 = 0,

pub fn slice(self: *const Results) []const Match {
    return self.matches[0..self.len];
}
