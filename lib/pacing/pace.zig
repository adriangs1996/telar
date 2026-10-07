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

/// The sustained frame budget of a host that reports no display rate.
/// Idle and input bursts may present earlier.
///
/// The budget is the display's own refresh interval wherever the host knows
/// it: 120 Hz on ProMotion, 144 or 165 on an external monitor. Presenting
/// faster than the display buys nothing, since vsync discards the extra
/// frames, so the display is the ceiling; a user may cap below it to save
/// power. A pacer takes the interval as a field, and the window and the
/// runtime set it from the display, so this value only covers hosts that
/// cannot tell, such as a terminal client, and the moment before a window
/// learns which display it is on.
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
/// A frame already in flight may not contain the echo. Applied cell updates
/// continue independently, and their next presentation should be eligible
/// immediately. A window of a few tens of milliseconds covers both and costs
/// extra frames only while the user is actually typing.
pub const default_input_grace: u64 = 30 * ns_per_ms;

/// Frames one host input may present through the grace window when credit
/// is spent. The runtime delivers one frame per pane in turn, so the echo can
/// sit behind one frame per busy pane; this covers a full tab of panes while
/// keeping an Enter that starts a flood from paying a window of unthrottled
/// frames.
pub const default_input_frames: u32 = 16;

/// The last cadence slot at or before `now`, so a late wakeup neither shifts
/// the cadence nor owes the slots it slept through.
pub fn latestCadenceSlot(deadline: u64, now: u64, interval: u64) u64 {
    std.debug.assert(interval != 0);
    if (now <= deadline) {
        return deadline;
    }

    const periods = (now - deadline) / interval;
    const advance = std.math.mul(u64, periods, interval) catch return now;
    return deadline +| advance;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
