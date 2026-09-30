const types = @import("types.zig");
const MarkerRemoval = @This();

direction: enum {
    left,
    right,
},
/// Editor steps from the cursor to the marker, taken again back after it.
steps: u16,
deletion: types.MarkerDeletion,
/// Deletion keys needed: one for an atomic placeholder, one per grapheme
/// for a pasted path.
deletions: u16 = 1,

pub fn keyCount(self: MarkerRemoval) usize {
    return @as(usize, self.steps) * 2 + self.deletions;
}
