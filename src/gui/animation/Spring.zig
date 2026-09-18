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
pub fn retarget(spring: *Spring, target: f64) void {
    if (std.math.isFinite(target)) {
        spring.target = target;
    }
}

/// Adds release velocity without discontinuously moving the current position.
/// Example: `spring.impulse(release_velocity - spring.velocity);`
pub fn impulse(spring: *Spring, delta_velocity: f64) void {
    const velocity = spring.velocity + delta_velocity;
    if (std.math.isFinite(velocity)) {
        spring.velocity = velocity;
    }
}

/// Example: `spring.reset(pointer_position);`
pub fn reset(spring: *Spring, value: f64) void {
    if (!std.math.isFinite(value)) {
        return;
    }

    spring.position = value;
    spring.target = value;
    spring.velocity = 0;
}

/// Rebases layout coordinates without turning an anchor correction into motion.
/// Example: `spring.translate(new_anchor_position - old_anchor_position);`
pub fn translate(spring: *Spring, delta: f64) void {
    const position = spring.position + delta;
    const target = spring.target + delta;
    if (!std.math.isFinite(position) or !std.math.isFinite(target)) {
        return;
    }

    spring.position = position;
    spring.target = target;
}

/// Example: `if (spring.active()) clock.requestAt(next_frame_ns);`
pub fn active(spring: Spring) bool {
    return spring.position != spring.target or spring.velocity != 0;
}

/// Clips the destination and stops only velocity pointing outside the bounds.
/// Example: `spring.constrain(0, content_height - viewport_height);`
pub fn constrain(spring: *Spring, minimum: f64, maximum: f64) void {
    if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum) or minimum > maximum) {
        return;
    }

    spring.position = std.math.clamp(spring.position, minimum, maximum);
    spring.target = std.math.clamp(spring.target, minimum, maximum);
    if ((spring.position == minimum and spring.velocity < 0) or (spring.position == maximum and spring.velocity > 0)) {
        spring.velocity = 0;
    }
}

test "spring impulses accelerate and retarget without changing position or velocity" {
    var spring: Spring = .{};
    try std.testing.expect(!spring.active());
    spring.retarget(120);
    try std.testing.expectEqual(@as(f64, 0), spring.position);
    try std.testing.expectEqual(@as(f64, 0), spring.velocity);
    spring.advance(1.0 / 120.0);
    try std.testing.expect(spring.position > 0 and spring.position < 120);
    try std.testing.expect(spring.velocity > 0);

    const before = spring;
    spring.retarget(-120);
    try std.testing.expectEqual(before.position, spring.position);
    try std.testing.expectEqual(before.velocity, spring.velocity);
    spring.advance(1.0 / 120.0);
    try std.testing.expect(spring.velocity < before.velocity);
    spring.advance(1);
    try std.testing.expectEqual(@as(f64, -120), spring.position);
    try std.testing.expect(!spring.active());
}

test "spring trajectories agree across refresh rates and missed frames" {
    const start: Spring = .{ .position = 3, .velocity = -17, .target = 203, .position_epsilon = 0, .velocity_epsilon = 0 };
    var sixty = start;
    var one_twenty = start;
    var missed = start;
    for (0..12) |_| {
        sixty.advance(1.0 / 60.0);
    }

    for (0..24) |_| {
        one_twenty.advance(1.0 / 120.0);
    }

    missed.advance(0.2);
    try std.testing.expectApproxEqAbs(missed.position, sixty.position, 1e-10);
    try std.testing.expectApproxEqAbs(missed.position, one_twenty.position, 1e-10);
    try std.testing.expectApproxEqAbs(missed.velocity, sixty.velocity, 1e-10);
    try std.testing.expectApproxEqAbs(missed.velocity, one_twenty.velocity, 1e-10);
}

test "spring release impulse preserves position and decelerates continuously" {
    var spring: Spring = .{ .position = 20, .target = 120, .frequency = 6 };
    spring.impulse(600);
    try std.testing.expectEqual(@as(f64, 20), spring.position);
    try std.testing.expectEqual(@as(f64, 120), spring.target);
    try std.testing.expectEqual(@as(f64, 600), spring.velocity);
    for (0..120) |_| {
        const previous = spring;
        spring.advance(1.0 / 60.0);
        try std.testing.expect(spring.velocity >= 0 and spring.velocity <= previous.velocity);
        try std.testing.expect(spring.position >= previous.position and spring.position <= spring.target);
    }

    spring.advance(10);
    try std.testing.expect(!spring.active());
    try std.testing.expectEqual(@as(f64, 120), spring.position);
}

test "spring layout translation preserves the remaining trajectory" {
    var original: Spring = .{};
    original.retarget(350);
    original.advance(0.04);
    var translated = original;
    translated.translate(-130);
    try std.testing.expectEqual(original.velocity, translated.velocity);

    original.advance(0.07);
    translated.advance(0.07);
    try std.testing.expectApproxEqAbs(original.position - 130, translated.position, 1e-10);
    try std.testing.expectApproxEqAbs(original.target - 130, translated.target, 1e-10);
    try std.testing.expectApproxEqAbs(original.velocity, translated.velocity, 1e-10);
}

test "spring at rest approaches its destination without overshoot" {
    var spring: Spring = .{};
    spring.retarget(120);
    for (0..120) |_| {
        const previous = spring.position;
        spring.advance(1.0 / 120.0);
        try std.testing.expect(spring.position >= previous and spring.position <= spring.target);
        try std.testing.expect(spring.velocity >= 0);
    }

    try std.testing.expectEqual(spring.target, spring.position);
    try std.testing.expectEqual(@as(f64, 0), spring.velocity);
    try std.testing.expect(!spring.active());
}

test "spring settles only when both position and velocity are negligible" {
    var spring: Spring = .{ .position = 0.001, .velocity = 1 };
    spring.advance(0.001);
    try std.testing.expect(@abs(spring.position) < spring.position_epsilon);
    try std.testing.expect(spring.velocity > spring.velocity_epsilon);
    try std.testing.expect(spring.active());
    spring.advance(1);
    try std.testing.expect(!spring.active());
    try std.testing.expectEqual(@as(f64, 0), spring.position);
    try std.testing.expectEqual(@as(f64, 0), spring.velocity);

    spring.retarget(10);
    spring.advance(0.01);
    spring.reset(5);
    try std.testing.expectEqual(@as(f64, 5), spring.position);
    try std.testing.expectEqual(@as(f64, 5), spring.target);
    try std.testing.expect(!spring.active());
}

test "spring rejects invalid input and safely consumes a very late frame" {
    var spring: Spring = .{ .position = 3, .velocity = 7, .target = 103 };
    const before = spring;
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |elapsed| {
        spring.advance(elapsed);
        try std.testing.expectEqualDeep(before, spring);
    }

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |invalid| {
        spring.retarget(invalid);
        spring.reset(invalid);
        spring.impulse(invalid);
        spring.translate(invalid);
        spring.constrain(0, invalid);
        try std.testing.expectEqualDeep(before, spring);
    }

    spring.advance(std.math.floatMax(f64));
    try std.testing.expectEqual(@as(f64, 103), spring.position);
    try std.testing.expect(!spring.active());
}

test "spring bounds absorb outward motion and preserve inward motion" {
    var spring: Spring = .{ .position = -5, .velocity = -20, .target = -120 };
    spring.constrain(0, 100);
    try std.testing.expectEqual(@as(f64, 0), spring.position);
    try std.testing.expect(!spring.active());

    spring = .{ .position = 110, .velocity = 20, .target = 150 };
    spring.constrain(0, 100);
    try std.testing.expectEqual(@as(f64, 100), spring.position);
    try std.testing.expect(!spring.active());

    spring = .{ .position = 100, .velocity = -20, .target = 10 };
    spring.constrain(0, 100);
    try std.testing.expectEqual(@as(f64, -20), spring.velocity);
    spring.advance(0.01);
    try std.testing.expect(spring.position < 100);
    spring.constrain(15, 15);
    try std.testing.expectEqual(@as(f64, 15), spring.position);
    try std.testing.expect(!spring.active());
}
