//! Current row geometry used to resolve a delivered reading position.
const ThreadItemControl = @import("ThreadItemControl.zig");

control: ThreadItemControl,
baseline: f64,
offset: f32,
maximum: f32,
step: f32,
limit: f64,
