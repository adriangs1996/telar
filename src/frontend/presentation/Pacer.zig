/// Bounds the frame rate without adding latency to an idle UI.
///
/// A naive throttle waits out the interval before every frame, so a keypress
/// into a still screen is up to 16ms late for no reason at all - and that
/// delay is exactly the one a user can feel, because it lands on the
/// keystroke they were paying attention to. Here credits accrue while the UI
/// is quiet, one per interval up to `burst`, each immediate frame spends one,
/// and only a frame that finds no credit waits for the next cadence slot.
const Pacer = @This();
const source_namespace = @import("pace.zig");
const std = @import("std");
pub const Record = struct {
    now: u64,
    scheduled_deadline: ?u64,
    absorbed: usize,
};

interval: u64 = source_namespace.default_interval,
/// Maximum credits held; zero makes every frame wait, which tests use to
/// exercise the scheduled path deterministically.
burst: u32 = source_namespace.default_burst,
/// Credits left at `anchor_ns`. Refill is computed from elapsed time, so
/// nothing has to tick while the UI idles.
credits: u32 = source_namespace.default_burst,
/// The cadence slot of the last presented frame. Null until the first
/// frame, so a program's opening frame is never delayed.
anchor_ns: ?u64 = null,
input_grace: u64 = source_namespace.default_input_grace,
input_frames: u32 = source_namespace.default_input_frames,
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
/// pacer.record(.{ .now = now_ns, .scheduled_deadline = deadline_ns, .absorbed = pending_updates });
/// ```
pub fn record(p: *Pacer, frame: Record) void {
    std.debug.assert(p.interval != 0);
    const usable = p.available(frame.now);
    if (usable == 0 and frame.scheduled_deadline == null) {
        p.input_frames_left -|= 1;
    }
    p.credits = usable -| 1;
    p.anchor_ns = if (frame.scheduled_deadline) |deadline|
        source_namespace.latestCadenceSlot(deadline, frame.now, p.interval)
    else
        frame.now;
    p.stats.drawn += 1;
    // The first message earned the frame; the rest rode along.
    p.stats.absorbed += frame.absorbed -| 1;
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
