//! What a child process printed, read within fixed bounds: each stream
//! either fails past its bound or keeps its newest bytes and counts what it
//! dropped, so a chatty command that succeeded never fails for its noise.

pub const ChildOutput = @import("ChildOutput.zig");
pub const Bound = @import("Bound.zig").Bound;
pub const Bounds = @import("Bounds.zig");
pub const KeptStream = @import("KeptStream.zig");

test {
    _ = @import("ChildOutput.zig");
}
