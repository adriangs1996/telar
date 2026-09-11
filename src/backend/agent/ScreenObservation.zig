const ScreenObservation = @This();
const Identity = @import("Identity.zig");
const source_namespace = @import("types.zig");
identity: Identity,
signal: source_namespace.ScreenSignal,
observed_at_ms: i64,
/// Monotonic PTY-read time; non-PTY observation producers may omit it.
observed_at_ns: ?i64 = null,
