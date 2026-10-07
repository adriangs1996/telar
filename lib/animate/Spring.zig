//! A critically damped scalar spring, independent of frame rate and host APIs.
//! Position and target share a coordinate system; velocity uses units/second.
const std = @import("std");

const Spring = @This();

position: f64 = 0,
velocity: f64 = 0,
target: f64 = 0,
frequency: f64 = 26,
position_epsilon: f64 = 0.01,
velocity_epsilon: f64 = 0.1,

/// Solves x'' + 2ωx' + ω²(x - target) = 0 for the actual elapsed time.
/// Invalid time is ignored; missed frames need no integration loop.
/// Example: `spring.advance(@as(f64, @floatFromInt(elapsed_ns)) / 1e9);`
pub fn advance(self: *Spring, elapsed_seconds: f64) void {
    if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds <= 0 or !self.active()) {
        return;
    }

    if (!std.math.isFinite(self.frequency) or self.frequency <= 0) {
        return;
    }

    const decay = @exp(-self.frequency * elapsed_seconds);
    if (decay == 0) {
        self.reset(self.target);
        return;
    }

    const offset = self.position - self.target;
    const coefficient = self.velocity + self.frequency * offset;
    const position = self.target + (offset + coefficient * elapsed_seconds) * decay;
    const velocity = (self.velocity - self.frequency * coefficient * elapsed_seconds) * decay;
    if (!std.math.isFinite(position) or !std.math.isFinite(velocity)) {
        self.reset(self.target);
        return;
    }

    self.position = position;
    self.velocity = velocity;
    if (@abs(position - self.target) <= self.position_epsilon and @abs(velocity) <= self.velocity_epsilon) {
        self.reset(self.target);
    }
}

/// Retains position and velocity when another impulse changes the destination.
/// Example: `spring.retarget(spring.target + wheel_distance);`
pub fn retarget(self: *Spring, target: f64) void {
    if (std.math.isFinite(target)) {
        self.target = target;
    }
}

/// Example: `spring.reset(pointer_position);`
pub fn reset(self: *Spring, value: f64) void {
    if (!std.math.isFinite(value)) {
        return;
    }

    self.position = value;
    self.target = value;
    self.velocity = 0;
}

/// Rebases layout coordinates without turning an anchor correction into motion.
/// Example: `spring.translate(new_anchor_position - old_anchor_position);`
pub fn translate(self: *Spring, delta: f64) void {
    const position = self.position + delta;
    const target = self.target + delta;
    if (!std.math.isFinite(position) or !std.math.isFinite(target)) {
        return;
    }

    self.position = position;
    self.target = target;
}

/// Example: `if (spring.active()) clock.requestAt(next_frame_ns);`
pub fn active(self: Spring) bool {
    return self.position != self.target or self.velocity != 0;
}
