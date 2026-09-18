//! One attachment's pixel trajectory and its last committed model coordinate.
const client = @import("telar-client");
const Motion = @This();

key: client.AgentKey,
motion: @import("../ScrollMotion.zig") = .{},
applied: f64 = 0,
anchor_revision: u64 = 0,
step: f64 = 24,
limit: f64 = 0,
has_older: bool = false,
has_newer: bool = false,
waiting: bool = false,
geometry_ready: bool = false,
last_precise: bool = false,

/// Page anchors change coordinates, while explicit navigation replaces motion.
/// Example: `entry.synchronize(pane, now_ns);`
pub fn synchronize(entry: *Motion, pane: *const client.Pane, now_ns: u64) void {
    if (entry.anchor_revision != pane.transcript_anchor_revision) {
        entry.motion.translate((pane.transcript_scroll - entry.applied) * entry.step);
    } else if (entry.applied != pane.transcript_scroll) {
        entry.motion.reset(pane.transcript_scroll * entry.step, now_ns);
    }

    entry.applied = pane.transcript_scroll;
    entry.anchor_revision = pane.transcript_anchor_revision;
}

/// Only delivered geometry may replace a trajectory's bounds and pixel scale.
/// Example: `entry.geometry(target, now_ns);`
pub fn geometry(entry: *Motion, target: @import("Target.zig"), now_ns: u64) void {
    const step: f64 = @max(1, target.scroll_step);
    if (entry.step != step) {
        entry.step = step;
        entry.motion.reset(entry.applied * step, now_ns);
    }

    // Input during a flight can postpone its anchor. These limits still use
    // that uncommitted coordinate system and would clip pending travel.
    if (target.thread_reanchor and entry.anchor_revision == target.thread_anchor_revision) {
        return;
    }

    entry.geometry_ready = true;
    entry.limit = target.scroll_limit;
    entry.has_older = target.thread_has_older;
    entry.has_newer = target.thread_has_newer;
    entry.bound(now_ns);
}

/// Retains direct movement blocked on page loading until the same gesture ends.
/// A new gesture or reversal takes control from the current visible position.
/// Example: `entry.input(normalized_pixel_event, now_ns);`
pub fn input(entry: *Motion, event: @import("../../input/ScrollEvent.zig"), now_ns: u64) void {
    if (!@import("std").math.isFinite(event.delta_y)) {
        return;
    }

    if (!entry.geometry_ready or entry.waiting) {
        entry.motion.hold(entry.motion.spring.position, now_ns);
    }

    const cancelled = event.phase == .cancel or event.momentum == .cancel;
    const continuing = event.phase == .update or event.phase == .end or event.momentum != .none;
    const pending = entry.motion.spring.target - entry.motion.spring.position;
    const retain = entry.waiting and entry.last_precise and event.precise and continuing and event.phase != .begin and !cancelled and (event.delta_y == 0 or pending * event.delta_y > 0);
    entry.motion.input(event, now_ns);
    if (retain) {
        entry.motion.spring.retarget(entry.motion.spring.target + pending);
    }

    entry.last_precise = event.precise and !cancelled;
    entry.bound(now_ns);
}

/// A provisional page edge parks time until delivery supplies more content.
/// Example: `entry.advance(now_ns);`
pub fn advance(entry: *Motion, now_ns: u64) void {
    if (!entry.geometry_ready or entry.waiting) {
        entry.motion.hold(entry.motion.spring.position, now_ns);
    } else {
        entry.motion.advance(now_ns);
    }

    entry.bound(now_ns);
}

/// Hard endpoints absorb outward velocity; missing pages retain pending travel.
/// Example: `entry.bound(now_ns);`
pub fn bound(entry: *Motion, now_ns: u64) void {
    if (!entry.geometry_ready) {
        return;
    }

    const maximum = entry.limit * entry.step;
    const budget = @as(f64, @import("std").math.maxInt(u32)) * entry.step;
    entry.motion.constrain(if (entry.has_newer) -budget else 0, if (entry.has_older) budget else maximum);
    const spring = entry.motion.spring;
    entry.waiting = (entry.has_newer and spring.position <= 0 and (spring.target < 0 or spring.velocity < 0)) or (entry.has_older and spring.position >= maximum and (spring.target > maximum or spring.velocity > 0));
    if (entry.waiting) {
        entry.motion.hold(@max(0, @min(maximum, spring.position)), now_ns);
    }
}

test "thread motion waits at a soft edge and resumes without spending loading time" {
    const std = @import("std");
    var entry: Motion = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 0 } };
    var edge = testGeometry(1);
    edge.thread_has_older = true;
    entry.geometry(edge, 0);
    entry.motion.input(.{ .delta_y = 120 }, 0);
    entry.advance(50 * std.time.ns_per_ms);
    try std.testing.expect(entry.waiting);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    try std.testing.expect(entry.motion.spring.velocity > 0);
    const parked = entry.motion.spring;
    var immediate = entry;

    entry.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqualDeep(parked, entry.motion.spring);
    try std.testing.expect(entry.waiting);
    entry.geometry(testGeometry(100), 10 * std.time.ns_per_s);
    immediate.geometry(testGeometry(100), 50 * std.time.ns_per_ms);
    try std.testing.expect(!entry.waiting);
    try std.testing.expectEqualDeep(parked, entry.motion.spring);

    entry.advance(10 * std.time.ns_per_s + 20 * std.time.ns_per_ms);
    immediate.advance(70 * std.time.ns_per_ms);
    try std.testing.expect(entry.motion.spring.position > parked.position);
    try std.testing.expectApproxEqAbs(immediate.motion.spring.position, entry.motion.spring.position, 1e-10);
    try std.testing.expectApproxEqAbs(immediate.motion.spring.velocity, entry.motion.spring.velocity, 1e-10);
    try std.testing.expectEqual(immediate.motion.spring.target, entry.motion.spring.target);
}

test "committed thread anchors translate velocity and remaining travel without restarting motion" {
    const std = @import("std");
    var pane = try testPane();
    defer pane.deinit();
    var pixels: @import("../ScrollMotion.zig") = .{};
    pixels.reset(1200, 0);
    pixels.input(.{ .delta_y = 120 }, 0);
    pixels.advance(30 * std.time.ns_per_ms);
    var entry: Motion = .{ .key = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation }, .motion = pixels, .applied = pixels.spring.position / 24 };
    entry.geometry(testGeometry(1000), 30 * std.time.ns_per_ms);
    _ = pane.scrollConversation(entry.applied);
    var untranslated = entry;
    const before = entry.motion.spring;

    _ = pane.scrollConversation(500);
    pane.transcript_anchor_revision += 1;
    entry.synchronize(&pane, 30 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(before.position + 500 * 24, entry.motion.spring.position, 1e-10);
    try std.testing.expectApproxEqAbs(before.target + 500 * 24, entry.motion.spring.target, 1e-10);
    try std.testing.expectEqual(before.velocity, entry.motion.spring.velocity);
    try std.testing.expectEqual(pane.transcript_scroll, entry.applied);
    try std.testing.expectEqual(pane.transcript_anchor_revision, entry.anchor_revision);

    entry.advance(60 * std.time.ns_per_ms);
    untranslated.advance(60 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(untranslated.motion.spring.position + 500 * 24, entry.motion.spring.position, 1e-10);
    try std.testing.expectApproxEqAbs(untranslated.motion.spring.velocity, entry.motion.spring.velocity, 1e-10);
}

test "uncommitted page limits cannot clip travel after newer input overtakes a frame" {
    const std = @import("std");
    var pane = try testPane();
    defer pane.deinit();
    pane.transcript_anchor_revision = 7;
    var pixels: @import("../ScrollMotion.zig") = .{};
    pixels.reset(20 * 24, 0);
    pixels.input(.{ .delta_y = -1200 }, 0);
    pixels.advance(std.time.ns_per_ms);
    var entry: Motion = .{ .key = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation }, .motion = pixels, .applied = pixels.spring.position / 24, .anchor_revision = pane.transcript_anchor_revision };
    var current = testGeometry(100);
    current.thread_has_newer = true;
    entry.geometry(current, std.time.ns_per_ms);
    _ = pane.scrollConversation(entry.applied);
    const before = entry.motion.spring;

    var pending = testGeometry(600);
    pending.thread_reanchor = true;
    pending.thread_scroll_value = 20;
    pending.thread_resolved_scroll = 520;
    pending.thread_anchor_revision = pane.transcript_anchor_revision;
    try std.testing.expect(pane.transcript_scroll != pending.thread_scroll_value);
    entry.geometry(pending, std.time.ns_per_ms);
    try std.testing.expectEqualDeep(before, entry.motion.spring);
    try std.testing.expectEqual(@as(f64, 100), entry.limit);
    try std.testing.expect(entry.has_newer);
    try std.testing.expect(entry.motion.spring.target < 0);

    _ = pane.scrollConversation(pending.thread_resolved_scroll - pending.thread_scroll_value);
    pane.transcript_anchor_revision += 1;
    entry.synchronize(&pane, std.time.ns_per_ms);
    entry.geometry(pending, std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 600), entry.limit);
    try std.testing.expect(!entry.has_newer);
    try std.testing.expectApproxEqAbs(before.target + 500 * 24, entry.motion.spring.target, 1e-10);
    try std.testing.expectApproxEqAbs(before.target - before.position, entry.motion.spring.target - entry.motion.spring.position, 1e-10);
    try std.testing.expectEqual(before.velocity, entry.motion.spring.velocity);
}

test "first thread impulse waits for committed geometry using the delivered pixel scale" {
    const std = @import("std");
    var pane = try testPane();
    defer pane.deinit();
    _ = pane.scrollConversation(20);
    var entry: Motion = .{ .key = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation }, .applied = pane.transcript_scroll };
    entry.motion.reset(pane.transcript_scroll * entry.step, 0);
    var pending = testGeometry(600);
    pending.scroll_step = 48;
    pending.thread_reanchor = true;
    pending.thread_scroll_value = 19;
    pending.thread_resolved_scroll = 519;
    entry.geometry(pending, 0);
    try std.testing.expect(!entry.geometry_ready);
    try std.testing.expectEqual(@as(f64, 48), entry.step);
    entry.input(.{ .delta_y = entry.step }, 0);
    entry.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 20 * 48), entry.motion.spring.position);
    try std.testing.expectEqual(@as(f64, 21 * 48), entry.motion.spring.target);
    try std.testing.expectEqual(@as(f64, 0), entry.motion.spring.velocity);

    _ = pane.scrollConversation(pending.thread_resolved_scroll - pending.thread_scroll_value);
    pane.transcript_anchor_revision += 1;
    entry.synchronize(&pane, 10 * std.time.ns_per_s);
    entry.geometry(pending, 10 * std.time.ns_per_s);
    try std.testing.expect(entry.geometry_ready);
    try std.testing.expectEqual(@as(f64, 520 * 48), entry.motion.spring.position);
    entry.advance(11 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 521), entry.motion.spring.position / entry.step);
    try std.testing.expect(!entry.motion.active());
}

test "precise thread samples and zero delta release retain all movement blocked on a page" {
    const std = @import("std");
    var entry: Motion = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 0 } };
    var edge = testGeometry(1);
    edge.thread_has_older = true;
    entry.geometry(edge, 0);
    entry.motion.reset(20, 0);
    entry.input(.{ .precise = true, .phase = .begin, .delta_y = 10 }, 0);
    try std.testing.expect(entry.waiting);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    entry.input(.{ .precise = true, .phase = .update, .delta_y = 8 }, std.time.ns_per_ms);
    entry.input(.{ .precise = true, .phase = .end }, 2 * std.time.ns_per_ms);
    entry.input(.{ .precise = true, .momentum = .update, .delta_y = 3 }, 3 * std.time.ns_per_ms);
    entry.input(.{ .precise = true, .momentum = .end }, 4 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    try std.testing.expectEqual(@as(f64, 41), entry.motion.spring.target);
    entry.advance(10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    entry.geometry(testGeometry(100), 10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    entry.advance(10 * std.time.ns_per_s + std.time.ns_per_ms);
    try std.testing.expect(entry.motion.spring.position > 24 and entry.motion.spring.position < 41);
    entry.advance(11 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 41), entry.motion.spring.position);
}

test "new direct gestures reversals and cancellation discard deferred thread movement" {
    const std = @import("std");
    const Event = @import("../../input/ScrollEvent.zig");
    const inputs = [_]Event{
        .{ .precise = true, .phase = .begin, .delta_y = 2 },
        .{ .precise = true, .phase = .update, .delta_y = -2 },
        .{ .precise = true, .phase = .cancel },
    };
    for (inputs, [_]f64{ 26, 22, 24 }) |event, expected| {
        var entry: Motion = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 0 } };
        var edge = testGeometry(1);
        edge.thread_has_older = true;
        entry.geometry(edge, 0);
        entry.input(.{ .precise = true, .phase = .begin, .delta_y = 120 }, 0);
        try std.testing.expect(entry.waiting);
        entry.input(event, std.time.ns_per_ms);
        try std.testing.expectEqual(expected, entry.motion.spring.target);
        entry.geometry(testGeometry(100), std.time.ns_per_ms);
        entry.advance(std.time.ns_per_s);
        try std.testing.expectEqual(expected, entry.motion.spring.position);
    }
}

test "direct input at a soft edge takes over without inheriting a wheel destination" {
    const std = @import("std");
    var entry: Motion = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 0 } };
    var edge = testGeometry(1);
    edge.thread_has_older = true;
    entry.geometry(edge, 0);
    entry.input(.{ .delta_y = 120 }, 0);
    entry.advance(50 * std.time.ns_per_ms);
    try std.testing.expect(entry.waiting);
    entry.input(.{ .precise = true, .phase = .update, .delta_y = 2 }, 51 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f64, 24), entry.motion.spring.position);
    try std.testing.expectEqual(@as(f64, 26), entry.motion.spring.target);
    try std.testing.expectEqual(@as(f64, 0), entry.motion.spring.velocity);
}

fn testGeometry(limit: f64) @import("Target.zig") {
    return .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .action = .{ .transcript = @enumFromInt(1) }, .scroll_limit = limit, .scroll_step = 24 };
}

fn testPane() !client.Pane {
    return client.Pane.init(@import("std").testing.allocator, .{
        .spec = .{
            .pane_id = @enumFromInt(1),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
            .size = .{ .cols = 2, .rows = 2 },
        },
        .attached = true,
    });
}
