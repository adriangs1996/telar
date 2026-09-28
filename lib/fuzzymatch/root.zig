//! Fuzzy matching for short strings such as paths and commands: fzy's
//! alignment score in integers, and the byte offsets that produced it.
//! What the strings are and how results are ordered is the caller's.

const scoring = @import("scoring.zig");

pub const Matrix = @import("Matrix.zig");
pub const max_needle_bytes = scoring.max_needle_bytes;
pub const max_haystack_bytes = scoring.max_haystack_bytes;
pub const max_score = scoring.max_score;
pub const overlong_score = scoring.overlong_score;
pub const score = scoring.score;
pub const match = scoring.match;

test {
    _ = @import("Matrix.zig");
    _ = @import("scoring.zig");
}
