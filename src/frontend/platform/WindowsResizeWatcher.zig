/// Notices resizes by looking, because the alternative steals keystrokes.
///
/// Windows reports a resize as a `WINDOW_BUFFER_SIZE_EVENT` record on the
/// console input handle - but reading records *consumes* them, and the same
/// handle carries the keyboard. A watcher that drained records to find resizes
/// would eat the input the parser is waiting for, and the symptom is dropped
/// characters under an unrelated subsystem.
///
/// So this asks for the size on a timer instead. It costs one cheap call every
/// hundred milliseconds and a resize is noticed within that window, which is
/// well under the time a human takes to finish dragging a window edge. The
/// honest alternative is to move *all* input behind this file and translate
/// console records centrally; that is the right long-term answer and a much
/// larger change than a resize watcher.
///
/// Recorded exception to `docs/engineering-invariants.md` ("Idle panes and
/// clients schedule no polling or repaint proportional to their count"): this
/// is one constant-cost poll per client on Windows only, independent of pane
/// count. It disappears when console records are translated centrally.
const ResizeWatcher = @This();
const Tty = @import("WindowsTty.zig");
const Size = @import("types.zig").Size;
const source_namespace = @import("windows.zig");
tty: *Tty,
last: Size,

const interval_ms = 100;

pub fn init(tty: *Tty) !ResizeWatcher {
    return .{ .tty = tty, .last = tty.size() };
}

pub fn deinit(_: *ResizeWatcher) void {}

pub fn wait(w: *ResizeWatcher, io: source_namespace.Io) source_namespace.Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromMilliseconds(interval_ms), .awake);
        const now = w.tty.size();
        if (now.cols != w.last.cols or now.rows != w.last.rows) {
            w.last = now;
            return;
        }
    }
}
