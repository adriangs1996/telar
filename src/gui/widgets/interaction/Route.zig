//! One synchronous input decision; events themselves remain borrowed by the
//! caller and are never stored in this result or a presentation registry.
const Target = @import("Target.zig");

consumed: bool = false,
target: ?Target = null,
focus_changed: bool = false,
