//! Pure array challenge: no native window, font, runtime or external dependency.
//! Test: zig test frame_challenge.zig
//! Measure: zig run -O ReleaseFast frame_challenge.zig
const std = @import("std");
const benchmark = @import("src/gui/experiments/frame/benchmark.zig");

pub fn main(init: std.process.Init) !void {
    try benchmark.main(init);
}

test {
    _ = @import("src/gui/experiments/frame/tests.zig");
}
