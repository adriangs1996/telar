const Results = @This();
const source_namespace = @import("goto_picker.zig");
const Match = @import("Match.zig");
matches: [source_namespace.max_results]Match = undefined,
len: u8 = 0,

pub fn slice(results: *const Results) []const Match {
    return results.matches[0..results.len];
}
