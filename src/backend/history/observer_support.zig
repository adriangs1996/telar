//! Bounded, asynchronous observation of one pane's terminal stream.
//!
//! The interactive emulator owns what the user sees. This observer owns a
//! second, disposable emulator used only to recover submitted commands. Raw
//! input, output, resize and exit events are copied into a double buffer by
//! the runtime thread and consumed in order by one observation actor. Kitty
//! graphics and glyph APCs are disabled here: history needs their framing,
//! not their payload decoding or storage.

const core = @import("telar-core");

const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;
const vt = @import("ghostty-vt");
const std = @import("std");

/// Room a control prompt adds around its text: the sender line
/// (`agent_control.max_sender_line_bytes`, 192), bracketed-paste framing and
/// the Enter a keyboard mode encodes, rounded up.
const prompt_framing_bytes = 1024;
/// Terminal bytes one observation batch holds; two alternate per pane. It
/// holds the largest input a client or a prompt can send whole, so the
/// observer never drops one for its size. A burst of output past it between
/// two observation passes drops the batch and resets the history emulator,
/// so commands in flight are not recorded, and the limit is reported.
pub const batch_bytes = 128 * 1024;
pub const batch_bytes_limit = core.Limit.declare("history.observer_batch_bytes", "bytes", batch_bytes);

comptime {
    std.debug.assert(batch_bytes >= core.max_input_bytes + prompt_framing_bytes);
}

/// Events one batch holds, with the same drop.
pub const batch_events = 512;
pub const batch_events_limit = core.Limit.declare("history.observer_batch_events", "events", batch_events);

/// An unchanged screen signal is handed over again after this long, so the
/// runtime refreshes its screen evidence well before that evidence expires.
pub const signal_refresh_ms: i64 = 15 * 1000;

pub const Event = union(enum) {
    input: Input,
    output: Output,
    resize: core.TerminalSize,
    shell_exit: struct {
        clock: Clock,
        exit_code: i32,
    },
};

/// Combines the manifest phrases visible on screen with the prompt-glyph scan.
/// A visible blocked phrase stands. An agent whose manifest declares its own
/// ready prompt is not subject to the generic glyph scan; for the rest the
/// glyph scan decides readiness and the phrases only confirm identity.
pub fn mergeSignals(table: *const core.Table, phrases: ?core.Signal, prompt: ?core.Signal) ?core.Signal {
    const signal = phrases orelse return prompt;

    if (signal.status == .blocked or table.declaresReadyPrompt(signal.provider)) {
        return signal;
    }

    var result = prompt orelse return signal;
    result.identity_confirmed = signal.provider == result.provider and signal.identity_confirmed;
    return result;
}

/// Cursor Agent's dialogs draw their options with the composer's arrow, so a
/// blocked phrase decides before the composer scan; any other phrase is
/// left to the scan, which reads the live composer instead of the text.
///
/// ```zig
/// const signal = mergeCursorSignals(phrase_signal, cursor_screen.scan(terminal));
/// ```
pub fn mergeCursorSignals(phrases: ?core.Signal, composer: ?core.Signal) ?core.Signal {
    if (phrases) |signal| {
        if (signal.status == .blocked) {
            return signal;
        }
    }

    return composer;
}

pub fn vtResize(size: core.TerminalSize) vt.Terminal.Resize {
    return .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
            .width = size.cell_width_px,
            .height = size.cell_height_px,
        } else null,
    };
}

const Input = struct {
    offset: u32,
    len: u32,
    shell_foreground: ?bool,
    clock: Clock,
};

const Output = struct {
    offset: u32,
    len: u32,
    shell_foreground: ?bool,
    clock: Clock,
};
