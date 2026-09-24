//! Frame-clocked motion: springs, timed transitions and the clock that
//! advances them.

pub const FrameClock = @import("FrameClock.zig");
pub const Spring = @import("Spring.zig");
pub const Transition = @import("Transition.zig");

test {
    _ = @import("FrameClock.zig");
    _ = @import("Spring.zig");
    _ = @import("Transition.zig");
}
