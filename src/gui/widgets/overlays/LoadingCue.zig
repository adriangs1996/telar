//! When to show that a replacement page is on its way. A reply that lands
//! within a few frames replaces the rows directly; dimming them and drawing
//! the loading line for one frame on every keystroke reads as a flash.
const std = @import("std");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const LoadingCue = @This();

/// How long a wait stays invisible; later replies show the cue.
pub const delay_ns = 150 * std.time.ns_per_ms;

/// When the current wait began, or null while nothing is pending.
since_ns: ?u64 = null,

/// Reports whether the cue shows this frame. A wait lasts while replacement
/// requests follow each other, so typing into a slow search still shows it.
/// Without a clock the composition is static and shows the cue at once.
/// Example: `const busy = cue.sample(history.phase == .loading, canvas.animation);`
pub fn sample(self: *LoadingCue, waiting: bool, animation: ?*FrameClock) bool {
    if (!waiting) {
        self.since_ns = null;
        return false;
    }

    const clock = animation orelse {
        self.since_ns = null;
        return true;
    };

    const since = self.since_ns orelse clock.now_ns;
    self.since_ns = since;
    const visible_ns = since +| delay_ns;
    if (clock.now_ns >= visible_ns) {
        return true;
    }

    clock.requestAt(visible_ns);
    return false;
}

test "a reply within the delay never shows the cue nor leaves a deadline" {
    var cue: LoadingCue = .{};
    var clock: FrameClock = .{};
    clock.begin(std.time.ns_per_s);
    try std.testing.expect(!cue.sample(true, &clock));
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_s + delay_ns), clock.deadline_ns);

    clock.begin(std.time.ns_per_s + delay_ns / 2);
    try std.testing.expect(!cue.sample(false, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    try std.testing.expectEqual(@as(?u64, null), cue.since_ns);
}

test "a late reply shows the cue once the delay elapses and a new wait starts over" {
    var cue: LoadingCue = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    try std.testing.expect(!cue.sample(true, &clock));

    clock.begin(delay_ns - 1);
    try std.testing.expect(!cue.sample(true, &clock));
    try std.testing.expectEqual(@as(?u64, delay_ns), clock.deadline_ns);

    clock.begin(delay_ns);
    try std.testing.expect(cue.sample(true, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);

    clock.begin(delay_ns * 2);
    try std.testing.expect(!cue.sample(false, &clock));
    try std.testing.expect(!cue.sample(true, &clock));
    try std.testing.expectEqual(@as(?u64, delay_ns * 3), clock.deadline_ns);
}

test "a static composition shows a pending wait at once" {
    var cue: LoadingCue = .{};
    try std.testing.expect(cue.sample(true, null));
    try std.testing.expect(!cue.sample(false, null));
}
