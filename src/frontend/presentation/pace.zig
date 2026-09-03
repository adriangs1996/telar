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
pub const default_interval: u64 = std.time.ns_per_s / 60;

/// Frames an idle UI may present back to back before the interval applies.
///
/// One keystroke is rarely one frame. A shell redraws its prompt in two or
/// three writes, a TUI repaints its status line after its body, and the
/// runtime turns each write that lands while a frame is unacknowledged into
/// the next frame. Capping at one immediate frame made every second frame of
/// an interaction wait a whole interval, which is the delay the throttle was
/// meant to keep off the keystroke. A small burst credit covers an interaction;
/// a sustained flood still exhausts it and settles on the interval.
pub const default_burst: u32 = 4;

/// How long after host input a frame presents without waiting for credit.
///
/// Under a flood from other panes the burst credit is always spent, and the
/// keystroke's echo would wait a whole interval behind the flood's frames.
/// The echo needs at most two immediate presentations: the frame already in
/// flight, whose acknowledgement releases the focused pane's frame, and that
/// frame itself. A window of a few tens of milliseconds covers both and costs
/// extra frames only while the user is actually typing.
pub const default_input_grace: u64 = 30 * ns_per_ms;

/// Frames one host input may present through the grace window when credit
/// is spent. The runtime delivers one frame per pane in turn, so the echo can
/// sit behind one frame per busy pane; this covers a full tab of panes while
/// keeping an Enter that starts a flood from paying a window of unthrottled
/// frames.
pub const default_input_frames: u32 = 16;

/// Bounds the frame rate without adding latency to an idle UI.
///
/// A naive throttle waits out the interval before every frame, so a keypress
/// into a still screen is up to 16ms late for no reason at all - and that
/// delay is exactly the one a user can feel, because it lands on the
/// keystroke they were paying attention to. Here credits accrue while the UI
/// is quiet, one per interval up to `burst`, each immediate frame spends one,
/// and only a frame that finds no credit waits for the next cadence slot.
pub const Pacer = struct {
    interval: u64 = default_interval,
    /// Maximum credits held; zero makes every frame wait, which tests use to
    /// exercise the scheduled path deterministically.
    burst: u32 = default_burst,
    /// Credits left at `anchor_ns`. Refill is computed from elapsed time, so
    /// nothing has to tick while the UI idles.
    credits: u32 = default_burst,
    /// The cadence slot of the last presented frame. Null until the first
    /// frame, so a program's opening frame is never delayed.
    anchor_ns: ?u64 = null,
    input_grace: u64 = default_input_grace,
    input_frames: u32 = default_input_frames,
    /// When the host last delivered input; frames inside the grace window
    /// after it never wait, up to `input_frames` of them.
    last_input_ns: ?u64 = null,
    /// Grace frames left for the current input.
    input_frames_left: u32 = 0,
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

    /// Absolute monotonic deadline for the next frame. Null means draw now.
    ///
    /// Returning the deadline instead of a duration matters once the caller
    /// hands the wait to another actor. A relative sleep starts when that actor
    /// gets CPU time and adds dispatch latency to every frame.
    pub fn waitUntil(p: *const Pacer, now: u64) ?u64 {
        if (p.available(now) != 0 or p.inputRecent(now)) {
            return null;
        }

        const anchor = p.anchor_ns orelse now;
        return anchor +| p.interval;
    }

    /// Records a frame presented at `now`.
    ///
    /// `scheduled_deadline` is the deadline returned by `waitUntil` when the
    /// frame had to wait. Scheduled frames stay on that cadence even if the OS
    /// wakes the actor late. Immediate frames anchor a fresh cadence because
    /// they only happen while credit is available.
    ///
    /// ```zig
    /// pacer.record(now_ns, deadline_ns, pending_updates);
    /// ```
    pub fn record(p: *Pacer, now: u64, scheduled_deadline: ?u64, absorbed: usize) void {
        std.debug.assert(p.interval != 0);
        const usable = p.available(now);
        if (usable == 0 and scheduled_deadline == null) {
            p.input_frames_left -|= 1;
        }
        p.credits = usable -| 1;
        p.anchor_ns = if (scheduled_deadline) |deadline|
            latestCadenceSlot(deadline, now, p.interval)
        else
            now;
        p.stats.drawn += 1;
        // The first message earned the frame; the rest rode along.
        p.stats.absorbed += absorbed -| 1;
    }

    /// Records host input at `now`, opening the grace window.
    ///
    /// ```zig
    /// pacer.noteInput(now_ns);
    /// ```
    pub fn noteInput(p: *Pacer, now: u64) void {
        p.last_input_ns = now;
        p.input_frames_left = p.input_frames;
    }

    pub fn noteThrottled(p: *Pacer) void {
        p.stats.throttled += 1;
    }

    pub fn noteDropped(p: *Pacer, n: usize) void {
        p.stats.dropped += n;
    }

    fn inputRecent(p: *const Pacer, now: u64) bool {
        const input = p.last_input_ns orelse return false;
        return p.input_frames_left != 0 and now -| input < p.input_grace;
    }

    /// Credits usable at `now`: what was left at the anchor plus one per
    /// interval elapsed since, capped at `burst`.
    fn available(p: *const Pacer, now: u64) u32 {
        const anchor = p.anchor_ns orelse return p.burst;
        const refilled = (now -| anchor) / p.interval;
        const total = @as(u64, p.credits) +| refilled;
        return @intCast(@min(total, p.burst));
    }
};

/// The last cadence slot at or before `now`, so a late wakeup neither shifts
/// the cadence nor owes the slots it slept through.
fn latestCadenceSlot(deadline: u64, now: u64, interval: u64) u64 {
    std.debug.assert(interval != 0);
    if (now <= deadline) {
        return deadline;
    }

    const periods = (now - deadline) / interval;
    const advance = std.math.mul(u64, periods, interval) catch return now;
    return deadline +| advance;
}

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
    // ever returns a deadline the UI feels sticky no matter how fast it draws.
    var p: Pacer = .{};
    try testing.expectEqual(@as(?u64, null), p.waitUntil(0));

    p.record(1000 * ns_per_ms, null, 1);
    // Long after the budget elapsed.
    try testing.expectEqual(@as(?u64, null), p.waitUntil(1100 * ns_per_ms));
}

test "an interaction's follow-up frames spend credit instead of waiting" {
    // A prompt redraw is two or three writes; each becomes a frame. None of
    // them may wait, or the second half of every keystroke lands 16ms late.
    var p: Pacer = .{ .interval = 16 * ns_per_ms };
    var now: u64 = 100 * ns_per_ms;
    var frame: u32 = 0;
    while (frame < default_burst) : (frame += 1) {
        try testing.expectEqual(@as(?u64, null), p.waitUntil(now));
        p.record(now, null, 1);
        now += ns_per_ms;
    }

    // Credit is spent: the next frame waits for the slot after the last one.
    try testing.expectEqual(@as(?u64, (100 + default_burst - 1 + 16) * ns_per_ms), p.waitUntil(now));
}

test "with no burst a second frame inside the budget gets an absolute deadline" {
    var p: Pacer = .{ .interval = 16 * ns_per_ms, .burst = 1, .credits = 1 };
    p.record(100 * ns_per_ms, null, 1);

    try testing.expectEqual(@as(?u64, 116 * ns_per_ms), p.waitUntil(104 * ns_per_ms));
    // Exactly on the boundary the frame is due.
    try testing.expectEqual(@as(?u64, null), p.waitUntil(116 * ns_per_ms));
}

test "a clock that does not advance keeps the same deadline" {
    var p: Pacer = .{ .interval = 16 * ns_per_ms, .burst = 1, .credits = 1 };
    p.record(500, null, 1);
    try testing.expectEqual(@as(?u64, 500 + 16 * ns_per_ms), p.waitUntil(500));
    try testing.expectEqual(@as(?u64, 500 + 16 * ns_per_ms), p.waitUntil(499));
}

test "credit refills one frame per interval of quiet" {
    var p: Pacer = .{ .interval = 10 * ns_per_ms, .burst = 3, .credits = 3 };
    p.record(0, null, 1);
    p.record(0, null, 1);
    p.record(0, null, 1);
    try testing.expectEqual(@as(?u64, 10 * ns_per_ms), p.waitUntil(5 * ns_per_ms));

    // One interval of quiet buys one immediate frame, not the whole burst.
    try testing.expectEqual(@as(?u64, null), p.waitUntil(10 * ns_per_ms));
    p.record(10 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, 20 * ns_per_ms), p.waitUntil(11 * ns_per_ms));

    // Long quiet caps at the burst.
    try testing.expectEqual(@as(?u64, null), p.waitUntil(1000 * ns_per_ms));
    p.record(1000 * ns_per_ms, null, 1);
    p.record(1000 * ns_per_ms, null, 1);
    p.record(1000 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, 1010 * ns_per_ms), p.waitUntil(1000 * ns_per_ms));
}

test "frames inside the input grace window never wait" {
    var p: Pacer = .{ .interval = 16 * ns_per_ms, .burst = 0, .credits = 0 };
    p.record(100 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, 116 * ns_per_ms), p.waitUntil(101 * ns_per_ms));

    // A keystroke lands: the in-flight frame and the echo frame both present.
    p.noteInput(101 * ns_per_ms);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(102 * ns_per_ms));
    p.record(102 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(104 * ns_per_ms));
    p.record(104 * ns_per_ms, null, 1);

    // The window closes and the flood is back on cadence.
    try testing.expectEqual(
        @as(?u64, (104 + 16) * ns_per_ms),
        p.waitUntil((101 + 30) * ns_per_ms),
    );
}

test "input grace is bounded in frames so a flood after Enter is paced" {
    var p: Pacer = .{ .interval = 16 * ns_per_ms, .burst = 0, .credits = 0, .input_frames = 2 };
    p.noteInput(0);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(1 * ns_per_ms));
    p.record(1 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(2 * ns_per_ms));
    p.record(2 * ns_per_ms, null, 1);

    // Two frames spent: the third waits even though the window is open.
    try testing.expectEqual(@as(?u64, 18 * ns_per_ms), p.waitUntil(3 * ns_per_ms));

    // New input refills the grace frames.
    p.noteInput(4 * ns_per_ms);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(5 * ns_per_ms));
}

test "a zero burst schedules every frame" {
    var p: Pacer = .{ .interval = 10 * ns_per_ms, .burst = 0, .credits = 0 };
    try testing.expectEqual(@as(?u64, 10 * ns_per_ms), p.waitUntil(0));
    p.record(10 * ns_per_ms, 10 * ns_per_ms, 1);
    try testing.expectEqual(@as(?u64, 20 * ns_per_ms), p.waitUntil(10 * ns_per_ms));
}

test "a late scheduled frame does not shift the cadence" {
    var p: Pacer = .{ .interval = 10 * ns_per_ms, .burst = 1, .credits = 1 };
    p.record(0, null, 1);
    const deadline = p.waitUntil(2 * ns_per_ms).?;
    try testing.expectEqual(10 * ns_per_ms, deadline);

    p.record(13 * ns_per_ms, deadline, 1);
    try testing.expectEqual(@as(?u64, 20 * ns_per_ms), p.waitUntil(13 * ns_per_ms));
}

test "a badly late frame skips missed cadence slots" {
    var p: Pacer = .{ .interval = 10 * ns_per_ms, .burst = 1, .credits = 1 };
    p.record(0, null, 1);
    const deadline = p.waitUntil(1 * ns_per_ms).?;

    p.record(35 * ns_per_ms, deadline, 1);
    // The frame lands on slot 30, and the next one waits for the slot after.
    try testing.expectEqual(@as(?u64, 40 * ns_per_ms), p.waitUntil(35 * ns_per_ms));
}

test "cadence arithmetic saturates at the end of monotonic time" {
    try testing.expectEqual(
        std.math.maxInt(u64),
        latestCadenceSlot(0, std.math.maxInt(u64), 1),
    );
}

test "an immediate frame after idle starts a fresh cadence" {
    var p: Pacer = .{ .interval = 10 * ns_per_ms, .burst = 1, .credits = 1 };
    p.record(0, null, 1);
    try testing.expectEqual(@as(?u64, null), p.waitUntil(100 * ns_per_ms));

    p.record(100 * ns_per_ms, null, 1);
    try testing.expectEqual(@as(?u64, 110 * ns_per_ms), p.waitUntil(101 * ns_per_ms));
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
        if (p.waitUntil(now) != null) continue;
        p.record(now, null, absorbed);
        absorbed = 0;
        frames += 1;
    }

    try testing.expectEqual(frames, p.stats.drawn);
    try testing.expect(frames <= 300 / 16 + 1 + default_burst);
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
