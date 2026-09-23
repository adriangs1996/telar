//! An item position copied from the delivered frame that received a disclosure.
const ThreadItemControl = @import("ThreadItemControl.zig");

control: ThreadItemControl,
sequence: u64 = 0,
baseline: f64,
offset: f32,
