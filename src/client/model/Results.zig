const goto_picker = @import("goto_picker.zig");
const Match = @import("Match.zig");
const Results = @This();

matches: [goto_picker.max_results]Match = undefined,
len: u8 = 0,

pub fn slice(results: *const Results) []const Match {
    return results.matches[0..results.len];
}
