const gfx = @import("gfx");
const quad = gfx.Quad;
const Stamp = @import("Stamp.zig");

pub const max_blocks = 8;

/// Caller-owned storage, disjoint from every input block, retained between calls.
output: []quad.Quad,
len: usize = 0,
previous: [max_blocks]Stamp = @splat(.{}),
count: usize = 0,
/// Models the consumer borrowing output; neither algorithm may modify it then.
borrowed: bool = false,
