//! Bounded, best-first matches of the command palette over the static catalogue.
const command_palette = @import("command_palette.zig");
const CommandMatch = @import("CommandMatch.zig");
const CommandResults = @This();

matches: [command_palette.entries.len]CommandMatch = undefined,
len: u8 = 0,

/// Example: `for (results.slice()) |match| draw(command_palette.entries[match.index]);`
pub fn slice(self: *const CommandResults) []const CommandMatch {
    return self.matches[0..self.len];
}
