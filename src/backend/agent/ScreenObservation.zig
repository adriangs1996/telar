const core = @import("telar-core");
const Identity = @import("Identity.zig");
const ScreenObservation = @This();

identity: Identity,
signal: core.Signal,
observed_at_ms: i64,
/// Monotonic PTY-read time; non-PTY observation producers may omit it.
observed_at_ns: ?i64 = null,
