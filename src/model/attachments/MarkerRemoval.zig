const types = @import("types.zig");
const MarkerRemoval = @This();

direction: enum {
    left,
    right,
},
steps: u8,
deletion: types.MarkerDeletion,
/// Deletion keys needed: one for an atomic placeholder, one per grapheme
/// for a pasted path.
deletions: u8 = 1,

pub fn keyCount(removal: MarkerRemoval) usize {
    return @as(usize, removal.steps) * 2 + removal.deletions;
}
