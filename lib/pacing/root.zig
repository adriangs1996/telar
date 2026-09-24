//! Time on the interactive path: the awake monotonic clock, one replaceable
//! deadline per worker, and the frame pacer that caps redraws without delaying
//! an idle keystroke.

pub const DeadlineScheduler = @import("DeadlineScheduler.zig");
pub const Pacer = @import("Pacer.zig");
pub const clock = @import("clock.zig");
pub const deadline_timer = @import("deadline_timer.zig");
pub const pace = @import("pace.zig");

test {
    _ = @import("DeadlineScheduler.zig");
    _ = @import("Pacer.zig");
    _ = @import("PacerStats.zig");
    _ = @import("Record.zig");
    _ = @import("clock.zig");
    _ = @import("deadline_timer.zig");
    _ = @import("pace.zig");
}
