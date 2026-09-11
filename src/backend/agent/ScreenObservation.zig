const Identity = @import("Identity.zig");
const Signal = @import("telar-core").Signal;
const ScreenObservation = @This();

identity: Identity,
signal: Signal,
observed_at_ms: i64,
/// Monotonic PTY-read time; non-PTY observation producers may omit it.
observed_at_ns: ?i64 = null,
