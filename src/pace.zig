const std = @import("std");

// Deciding when to draw, and what to throw away first.
//
// A terminal UI that redraws once per event has no upper bound on its frame
// rate, and the events are not its own: an agent printing a build log produces
// thousands of screen changes a second, a held arrow key autorepeats, a mouse
// drag reports every pixel. Redrawing for each one burns a core to produce
// frames no eye resolves, and worse, it makes the program slower the more it
// has to say.
//
// The fix is two separate ideas that are easy to confuse:
//
//   - *Throttling* bounds how often a frame goes out. It costs latency, and
//     the whole trick is to spend that cost only during a burst.
//   - *Coalescing* decides what survives when several messages arrive between
//     frames. This is not "keep the last one": a resize superseded by another
//     resize is genuinely redundant, whereas a keystroke superseded by another
//     keystroke is a dropped character.
//
// Neither needs a clock or a terminal, so neither is here. Time arrives as a
// number, which is what lets a burst be tested without ever sleeping.

pub const ns_per_ms: u64 = 1_000_000;

/// The frame budget. One frame at 60Hz, which is the fastest a terminal
/// emulator will present anyway, so drawing more often puts bytes on a pipe
/// that nothing downstream will show.
pub const default_interval: u64 = 16 * ns_per_ms;

/// Bounds the frame rate without adding latency to an idle UI.
///
/// The property that matters is the second half. A naive throttle waits out
/// the interval before every frame, so a keypress into a still screen is up to
/// 16ms late for no reason at all - and that delay is exactly the one a user
/// can feel, because it lands on the keystroke they were paying attention to.
/// Here an idle UI draws immediately and only a second frame inside the same
/// budget waits.
pub const Pacer = struct {
    interval: u64 = default_interval,
    /// When the last frame went out, in monotonic nanoseconds. Null until the
    /// first frame, so a program's opening frame is never delayed.
    last: ?u64 = null,
    stats: Stats = .{},

    pub const Stats = struct {
        /// Frames actually drawn.
        drawn: u64 = 0,
        /// Frames that had to wait for the budget. The ratio against `drawn`
        /// is how much of the session was a burst.
        throttled: u64 = 0,
        /// Messages that were folded into a frame rather than getting one of
        /// their own. This is the number the throttle exists to produce.
        absorbed: u64 = 0,
        /// Messages dropped as superseded.
        dropped: u64 = 0,
    };

    /// Nanoseconds to wait before `now` may become a frame; zero means draw.
    pub fn waitFor(p: *const Pacer, now: u64) u64 {
        const last = p.last orelse return 0;
        // Saturating: a monotonic clock may return the same value twice, and
        // is only promised not to go backwards across *consecutive* calls.
        // Wrapping here would produce a wait of roughly six hundred years.
        const elapsed = now -| last;
        if (elapsed >= p.interval) return 0;
        return p.interval - elapsed;
    }

    /// Records that a frame went out at `now`.
    pub fn record(p: *Pacer, now: u64, absorbed: usize) void {
        p.last = now;
        p.stats.drawn += 1;
        // The first message earned the frame; the rest rode along.
        p.stats.absorbed += absorbed -| 1;
    }

    pub fn noteThrottled(p: *Pacer) void {
        p.stats.throttled += 1;
    }

    pub fn noteDropped(p: *Pacer, n: usize) void {
        p.stats.dropped += n;
    }
};

/// The most distinct collapsible kinds a single batch will fold.
///
/// A UI has a handful - resize, pointer motion - so this is generous. Past it
/// the batch is left alone rather than partly folded, because dropping some
/// duplicates and not others is harder to reason about than dropping none.
const max_kinds = 16;

/// Collapses superseded messages in place, returning the surviving count.
///
/// `keyOf` answers, for one message, whether a later message of the same kind
/// makes it redundant. Returning null means "this must be delivered" and is
/// the right answer for anything carrying information the newer message does
/// not contain - every keystroke, every click, every byte of agent output.
/// Returning a key means the newest of that key is the only one worth keeping:
/// a window resized twice was only ever going to end at the second size.
///
/// Order is preserved, and a survivor keeps the position of its *last*
/// occurrence, so a resize that happened after three keystrokes is still
/// applied after them.
pub fn coalesce(comptime T: type, items: []T, comptime keyOf: fn (T) ?u32) usize {
    if (items.len < 2) return items.len;

    var seen: [max_kinds]u32 = undefined;
    var seen_len: usize = 0;

    // Backwards, because the survivor of a key is its last occurrence, and
    // walking from the end makes the first one met the one to keep. Survivors
    // are packed against the end of the same array; every write lands on an
    // index already read, so no allocation and no second buffer.
    var write = items.len;
    var i = items.len;
    outer: while (i > 0) {
        i -= 1;
        if (keyOf(items[i])) |key| {
            for (seen[0..seen_len]) |s| if (s == key) continue :outer;
            if (seen_len == max_kinds) {
                // Out of room to track kinds. Keep everything from here down
                // rather than fold unpredictably.
                while (true) {
                    write -= 1;
                    items[write] = items[i];
                    if (i == 0) break;
                    i -= 1;
                }
                break;
            }
            seen[seen_len] = key;
            seen_len += 1;
        }
        write -= 1;
        items[write] = items[i];
    }

    const len = items.len - write;
    std.mem.copyForwards(T, items[0..len], items[write..]);
    return len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an idle ui draws immediately" {
    // The delay a throttle adds is only acceptable while it is invisible, and
    // it is visible precisely here: one keypress into a still screen. If this
    // ever returns non-zero the UI feels sticky no matter how fast it draws.
    var p: Pacer = .{};
    try testing.expectEqual(@as(u64, 0), p.waitFor(0));

    p.record(1000 * ns_per_ms, 1);
    // Long after the budget elapsed.
    try testing.expectEqual(@as(u64, 0), p.waitFor(1100 * ns_per_ms));
}

test "a second frame inside the budget waits out the remainder" {
    var p: Pacer = .{};
    p.record(100 * ns_per_ms, 1);

    // 4ms in: 12 left.
    try testing.expectEqual(12 * ns_per_ms, p.waitFor(104 * ns_per_ms));
    // Exactly on the boundary: no wait, not a one nanosecond wait.
    try testing.expectEqual(@as(u64, 0), p.waitFor(116 * ns_per_ms));
}

test "a clock that does not advance cannot produce a six hundred year wait" {
    // `monotonic` promises not to go backwards, not to move. Two calls inside
    // one tick return the same number, and subtracting them unsaturated
    // underflows into a wait no user outlives.
    var p: Pacer = .{ .interval = 16 * ns_per_ms };
    p.record(500, 1);
    try testing.expectEqual(16 * ns_per_ms, p.waitFor(500));
    try testing.expect(p.waitFor(499) <= 16 * ns_per_ms);
}

test "a burst is bounded and the frames it skips are counted" {
    // 300 events one millisecond apart. At one frame per event that is 300
    // frames; the budget allows about a fifth of that.
    var p: Pacer = .{};
    var absorbed: usize = 0;
    var now: u64 = 0;
    var frames: u64 = 0;

    while (now < 300 * ns_per_ms) : (now += ns_per_ms) {
        absorbed += 1;
        if (p.waitFor(now) > 0) continue;
        p.record(now, absorbed);
        absorbed = 0;
        frames += 1;
    }

    try testing.expectEqual(frames, p.stats.drawn);
    try testing.expect(frames <= 300 / 16 + 2);
    // Every event that did not earn a frame rode along on one.
    try testing.expect(p.stats.absorbed >= 250);
}

// A message shaped like the ones a real loop carries.
const Msg = union(enum) {
    key: u8,
    resize,
    mouse_move: struct { x: u16, y: u16 },
    click,

    fn key_of(m: Msg) ?u32 {
        return switch (m) {
            // A resize supersedes a resize: only the final size is real.
            .resize => 1,
            // Pointer motion supersedes motion: hover is a function of where
            // the pointer is now, not of the path it took.
            .mouse_move => 2,
            // Everything else carries information nothing later replaces.
            .key, .click => null,
        };
    }
};

fn fold(items: []Msg) usize {
    return coalesce(Msg, items, Msg.key_of);
}

test "no keystroke is ever dropped" {
    // The failure this guards is the one users report as "it swallowed a
    // character". Any coalescing rule that treats keys as superseding each
    // other produces it, and it is invisible until someone types fast.
    var items = [_]Msg{ .{ .key = 'h' }, .{ .key = 'o' }, .{ .key = 'l' }, .{ .key = 'a' } };
    try testing.expectEqual(@as(usize, 4), fold(&items));
    try testing.expectEqualSlices(u8, "hola", &.{
        items[0].key, items[1].key, items[2].key, items[3].key,
    });
}

test "only the last resize survives" {
    var items = [_]Msg{ .resize, .resize, .resize };
    try testing.expectEqual(@as(usize, 1), fold(&items));
}

test "the survivor keeps the position of its last occurrence" {
    // A resize that arrived after three keystrokes has to be applied after
    // them, or the keys are handled against a layout that no longer exists.
    var items = [_]Msg{ .resize, .{ .key = 'a' }, .{ .key = 'b' }, .resize };
    try testing.expectEqual(@as(usize, 3), fold(&items));
    try testing.expectEqual(@as(u8, 'a'), items[0].key);
    try testing.expectEqual(@as(u8, 'b'), items[1].key);
    try testing.expect(items[2] == .resize);
}

test "kinds fold independently of each other" {
    var items = [_]Msg{
        .{ .mouse_move = .{ .x = 1, .y = 1 } },
        .resize,
        .{ .mouse_move = .{ .x = 2, .y = 2 } },
        .{ .key = 'q' },
        .{ .mouse_move = .{ .x = 9, .y = 9 } },
        .resize,
    };
    try testing.expectEqual(@as(usize, 3), fold(&items));
    try testing.expectEqual(@as(u8, 'q'), items[0].key);
    // The newest position, not the path that led to it.
    try testing.expectEqual(@as(u16, 9), items[1].mouse_move.x);
    try testing.expect(items[2] == .resize);
}

test "a drag collapses to where the pointer ended up" {
    var items: [64]Msg = undefined;
    for (&items, 0..) |*m, i| m.* = .{ .mouse_move = .{ .x = @intCast(i), .y = 0 } };
    try testing.expectEqual(@as(usize, 1), fold(&items));
    try testing.expectEqual(@as(u16, 63), items[0].mouse_move.x);
}

test "folding an empty or single batch is a no-op" {
    var none: [0]Msg = .{};
    try testing.expectEqual(@as(usize, 0), fold(&none));
    var one = [_]Msg{.resize};
    try testing.expectEqual(@as(usize, 1), fold(&one));
}

test "more kinds than can be tracked keeps everything rather than some" {
    // Partial folding would be worse than none: which duplicates survived
    // would depend on where in the batch the seventeenth kind appeared.
    const Many = struct {
        k: u32,
        fn key_of(m: @This()) ?u32 {
            return m.k;
        }
    };
    var items: [max_kinds * 2]Many = undefined;
    for (&items, 0..) |*m, i| m.* = .{ .k = @intCast(i) };
    try testing.expectEqual(items.len, coalesce(Many, &items, Many.key_of));
    // Order intact.
    for (items, 0..) |m, i| try testing.expectEqual(@as(u32, @intCast(i)), m.k);
}
