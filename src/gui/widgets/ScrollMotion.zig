//! Physical-pixel scroll motion owned by one visible pane. Native gestures
//! remain direct; discrete input and hosts without inertia use one scalar spring.
const std = @import("std");
const Spring = @import("../animation/Spring.zig");
const ScrollEvent = @import("../input/ScrollEvent.zig");
const ScrollMotion = @This();

const wheel_frequency = 26;
const inertia_frequency = 6;
const stale_sample_ms = 100;
const minimum_release_speed = 40;
const maximum_release_speed = 12_000;

spring: Spring = .{},
timestamp_ns: u64 = 0,
finger_down: bool = false,
sample_time_ms: ?u32 = null,
pending_delta: f64 = 0,
sample_duration_ms: u32 = 0,
sample_velocity: f64 = 0,
sample_has_velocity: bool = false,
release_velocity: f64 = 0,
has_velocity: bool = false,
last_delta_ns: ?u64 = null,
last_delta_time_ms: u32 = 0,

/// Example: `motion.reset(pane_scroll_pixels, clock.now_ns);`
pub fn reset(motion: *ScrollMotion, position: f64, now_ns: u64) void {
    motion.spring.reset(position);
    motion.timestamp_ns = now_ns;
    motion.clearGesture();
}

/// The caller converts delta_y to physical pixels in the pane's direction.
/// Precise native momentum is consumed directly without a second inertia tail.
/// Example: `motion.input(pixel_event, now_ns);`
pub fn input(motion: *ScrollMotion, event: ScrollEvent, now_ns: u64) void {
    if (!std.math.isFinite(event.delta_y)) {
        return;
    }

    if (event.phase == .cancel or event.momentum == .cancel) {
        motion.reset(motion.spring.position, now_ns);
        return;
    }

    if (!event.precise) {
        motion.advance(now_ns);
        motion.clearGesture();
        motion.spring.frequency = wheel_frequency;
        const remaining = motion.spring.target - motion.spring.position;
        const direction = if (remaining != 0) remaining else motion.spring.velocity;
        const reversed = (event.delta_y < 0 and direction > 0) or (event.delta_y > 0 and direction < 0);
        const origin = if (reversed) motion.spring.position else motion.spring.target;
        motion.spring.retarget(origin + event.delta_y);
        return;
    }

    motion.timestamp_ns = @max(motion.timestamp_ns, now_ns);
    motion.spring.reset(motion.spring.position + event.delta_y);
    if (!event.kinetic or event.momentum != .none) {
        motion.clearGesture();
        return;
    }

    if (event.phase == .begin or !motion.finger_down) {
        motion.clearGesture();
        motion.finger_down = true;
        motion.sample_time_ms = event.time_ms;
    } else {
        motion.recordVelocity(event);
    }

    if (event.delta_y != 0) {
        motion.last_delta_ns = now_ns;
        motion.last_delta_time_ms = event.time_ms;
    }

    if (event.phase == .end) {
        motion.release(event, now_ns);
    }
}

/// Samples actual elapsed time once; delayed frames require no replay loop.
/// Example: `motion.advance(clock.now_ns);`
pub fn advance(motion: *ScrollMotion, now_ns: u64) void {
    const elapsed = now_ns -| motion.timestamp_ns;
    motion.timestamp_ns = @max(motion.timestamp_ns, now_ns);
    motion.spring.advance(@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s);
}

/// Moves the coordinate origin after pagination without changing velocity.
/// Example: `motion.translate(resolved_anchor_pixels - old_anchor_pixels);`
pub fn translate(motion: *ScrollMotion, delta: f64) void {
    motion.spring.translate(delta);
}

/// Parks at a temporary page edge without spending travel while data is absent.
/// Example: `motion.hold(loaded_history_edge, clock.now_ns);`
pub fn hold(motion: *ScrollMotion, position: f64, now_ns: u64) void {
    if (!std.math.isFinite(position)) {
        return;
    }

    const target = motion.spring.target;
    motion.spring.translate(position - motion.spring.position);
    motion.spring.retarget(target);
    motion.timestamp_ns = @max(motion.timestamp_ns, now_ns);
}

/// Example: `motion.constrain(0, maximum_scroll_pixels);`
pub fn constrain(motion: *ScrollMotion, minimum: f64, maximum: f64) void {
    motion.spring.constrain(minimum, maximum);
}

/// A finger gesture alone requests no frames; its native events supply updates.
/// Example: `if (motion.active()) clock.requestAt(next_frame_ns);`
pub fn active(motion: ScrollMotion) bool {
    return motion.spring.active();
}

fn clearGesture(motion: *ScrollMotion) void {
    motion.finger_down = false;
    motion.sample_time_ms = null;
    motion.pending_delta = 0;
    motion.sample_duration_ms = 0;
    motion.sample_velocity = 0;
    motion.sample_has_velocity = false;
    motion.release_velocity = 0;
    motion.has_velocity = false;
    motion.last_delta_ns = null;
}

fn recordVelocity(motion: *ScrollMotion, event: ScrollEvent) void {
    const previous = motion.sample_time_ms orelse event.time_ms;
    const elapsed_ms = event.time_ms -% previous;
    if (elapsed_ms == 0) {
        motion.pending_delta += event.delta_y;
        motion.updateVelocity();
        return;
    }

    motion.sample_time_ms = event.time_ms;
    if (elapsed_ms > stale_sample_ms) {
        motion.pending_delta = 0;
        motion.sample_duration_ms = 0;
        motion.release_velocity = 0;
        motion.has_velocity = false;
        return;
    }

    if (event.delta_y == 0) {
        return;
    }

    motion.pending_delta = event.delta_y;
    motion.sample_duration_ms = elapsed_ms;
    motion.sample_velocity = motion.release_velocity;
    motion.sample_has_velocity = motion.has_velocity;
    motion.updateVelocity();
}

fn updateVelocity(motion: *ScrollMotion) void {
    if (motion.sample_duration_ms == 0) {
        return;
    }

    const measured = std.math.clamp(motion.pending_delta * 1000 / @as(f64, @floatFromInt(motion.sample_duration_ms)), -maximum_release_speed, maximum_release_speed);
    const changed_direction = measured * motion.sample_velocity < 0;
    const weight = if (!motion.sample_has_velocity or changed_direction) 1 else 1 - @exp(-@as(f64, @floatFromInt(motion.sample_duration_ms)) / 32);
    motion.release_velocity = motion.sample_velocity + (measured - motion.sample_velocity) * weight;
    motion.has_velocity = true;
}

fn release(motion: *ScrollMotion, event: ScrollEvent, now_ns: u64) void {
    const last_delta = motion.last_delta_ns orelse {
        motion.clearGesture();
        return;
    };

    const native_age_ms = event.time_ms -% motion.last_delta_time_ms;
    const elapsed_age_ms = (now_ns -| last_delta) / std.time.ns_per_ms;
    const age_ms = @max(native_age_ms, elapsed_age_ms);
    const velocity = motion.release_velocity;
    const valid = motion.has_velocity and age_ms < stale_sample_ms and @abs(velocity) >= minimum_release_speed;
    motion.clearGesture();
    if (!valid) {
        return;
    }

    // This critically damped initial state gives v(t) = v(0) exp(-frequency*t).
    motion.spring.frequency = inertia_frequency;
    motion.spring.retarget(motion.spring.position + velocity / inertia_frequency);
    motion.spring.impulse(velocity);
}

test "wheel scroll accelerates and repeated input retains velocity" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .delta_y = 120 }, 0);
    try std.testing.expectEqual(@as(f64, 0), motion.spring.position);
    try std.testing.expect(motion.active());
    motion.advance(20 * std.time.ns_per_ms);
    try std.testing.expect(motion.spring.position > 0 and motion.spring.position < 120);
    try std.testing.expect(motion.spring.velocity > 0);

    const before = motion.spring;
    motion.input(.{ .delta_y = 40 }, 20 * std.time.ns_per_ms);
    try std.testing.expectEqual(before.position, motion.spring.position);
    try std.testing.expectEqual(before.velocity, motion.spring.velocity);
    try std.testing.expectEqual(@as(f64, 160), motion.spring.target);
    motion.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 160), motion.spring.position);
    try std.testing.expect(!motion.active());
}

test "a small opposing wheel impulse reverses remaining travel while preserving velocity" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .delta_y = 120 }, 0);
    motion.advance(20 * std.time.ns_per_ms);
    const before = motion.spring;
    motion.input(.{ .delta_y = -24 }, 20 * std.time.ns_per_ms);
    try std.testing.expectEqual(before.position, motion.spring.position);
    try std.testing.expectEqual(before.velocity, motion.spring.velocity);
    try std.testing.expectEqual(before.position - 24, motion.spring.target);
    motion.advance(36 * std.time.ns_per_ms);
    try std.testing.expect(motion.spring.velocity < before.velocity);
    motion.advance(200 * std.time.ns_per_ms);
    try std.testing.expect(motion.spring.velocity < 0);
    motion.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(before.position - 24, motion.spring.position);
    try std.testing.expect(!motion.active());
}

test "native precise input and momentum follow their exact deltas without extra inertia" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .delta_y = 200 }, 0);
    motion.advance(20 * std.time.ns_per_ms);
    const initial = motion.spring.position;
    motion.input(.{ .precise = true, .delta_y = 0.25, .phase = .begin }, 25 * std.time.ns_per_ms);
    try std.testing.expectEqual(initial + 0.25, motion.spring.position);
    try std.testing.expect(!motion.active());
    motion.input(.{ .precise = true, .delta_y = 1.5, .momentum = .update }, 30 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .momentum = .end }, 40 * std.time.ns_per_ms);
    motion.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(initial + 1.75, motion.spring.position);
    try std.testing.expect(!motion.active());
}

test "kinetic finger input stays direct and release decelerates without a position jump" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .delta_y = 10, .time_ms = 100 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .update, .delta_y = 10, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 20), motion.spring.position);
    try std.testing.expect(!motion.active());
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 20), motion.spring.position);
    try std.testing.expect(motion.active());

    const velocity = motion.spring.velocity;
    motion.advance(32 * std.time.ns_per_ms);
    try std.testing.expect(motion.spring.position > 20);
    try std.testing.expect(motion.spring.velocity > 0 and motion.spring.velocity < velocity);
    motion.advance(10 * std.time.ns_per_s);
    try std.testing.expect(!motion.active());
}

test "batched kinetic deltas preserve velocity samples across timestamp wrap" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .delta_y = 1, .time_ms = std.math.maxInt(u32) - 9 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 4, .time_ms = 0 }, 10 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 3, .time_ms = 0 }, 10 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 7, .time_ms = 10 }, 20 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 10 }, 20 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 15), motion.spring.position);
    try std.testing.expectApproxEqAbs(@as(f64, 700), motion.spring.velocity, 1e-10);
}

test "kinetic release includes every delta sharing its final native timestamp" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 0 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 4, .time_ms = 10 }, 10 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 3, .time_ms = 10 }, 10 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 1, .phase = .end, .time_ms = 10 }, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 8), motion.spring.position);
    try std.testing.expectApproxEqAbs(@as(f64, 800), motion.spring.velocity, 1e-10);
}

test "kinetic stale release and cancellation park without requesting frames" {
    var motion: ScrollMotion = .{};
    const begin: ScrollEvent = .{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 0 };
    const update: ScrollEvent = .{ .precise = true, .kinetic = true, .phase = .update, .delta_y = 10, .time_ms = 16 };
    motion.input(begin, 0);
    motion.input(update, 16 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 16 }, 200 * std.time.ns_per_ms);
    try std.testing.expect(!motion.active());
    motion.reset(0, 0);
    motion.input(begin, 0);
    motion.input(update, 16 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .cancel, .time_ms = 16 }, 16 * std.time.ns_per_ms);
    motion.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 10), motion.spring.position);
    try std.testing.expect(!motion.active());
}

test "slow finger release and an invalid native time sequence produce no inertia" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 100 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 0.1, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 0.1), motion.spring.position);
    try std.testing.expect(!motion.active());

    motion.reset(0, 0);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 100 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 10, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 10, .time_ms = 115 }, 20 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 115 }, 20 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 20), motion.spring.position);
    try std.testing.expect(!motion.active());
}

test "kinetic estimates cap release speed even with unusually large direct deltas" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 0 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 1000, .time_ms = 1 }, std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 1 }, std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 1000), motion.spring.position);
    try std.testing.expectEqual(@as(f64, maximum_release_speed), motion.spring.velocity);
}

test "new finger gesture cancels release velocity and bounds absorb outward motion" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 100 }, 0);
    motion.input(.{ .precise = true, .kinetic = true, .delta_y = 10, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 116 }, 16 * std.time.ns_per_ms);
    motion.constrain(0, 10);
    try std.testing.expect(!motion.active());
    motion.input(.{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 120 }, 20 * std.time.ns_per_ms);
    motion.input(.{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 120 }, 20 * std.time.ns_per_ms);
    try std.testing.expect(!motion.active());
}

test "scroll anchoring translates both endpoints while keeping the same trajectory" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .delta_y = 120 }, 0);
    motion.advance(20 * std.time.ns_per_ms);
    var translated = motion;
    translated.translate(500);
    motion.advance(50 * std.time.ns_per_ms);
    translated.advance(50 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(motion.spring.position + 500, translated.spring.position, 1e-10);
    try std.testing.expectApproxEqAbs(motion.spring.target + 500, translated.spring.target, 1e-10);
    try std.testing.expectApproxEqAbs(motion.spring.velocity, translated.spring.velocity, 1e-10);
}

test "temporary history edges preserve motion without integrating time spent waiting" {
    var motion: ScrollMotion = .{};
    motion.input(.{ .delta_y = 120 }, 0);
    motion.advance(20 * std.time.ns_per_ms);
    const velocity = motion.spring.velocity;
    const target = motion.spring.target;
    motion.hold(10, 20 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 10), motion.spring.position);
    try std.testing.expectEqual(velocity, motion.spring.velocity);
    try std.testing.expectEqual(target, motion.spring.target);
    var uninterrupted = motion;

    motion.hold(10, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(velocity, motion.spring.velocity);
    try std.testing.expectEqual(target, motion.spring.target);
    uninterrupted.advance(40 * std.time.ns_per_ms);
    motion.advance(10 * std.time.ns_per_s + 20 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(uninterrupted.spring.position, motion.spring.position, 1e-10);
    try std.testing.expectApproxEqAbs(uninterrupted.spring.velocity, motion.spring.velocity, 1e-10);
}
