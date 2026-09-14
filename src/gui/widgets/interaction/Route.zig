//! One synchronous input decision; events themselves remain borrowed by the
//! caller and are never stored in this result or a presentation registry.
consumed: bool = false,
target: ?@import("Target.zig") = null,
focus_changed: bool = false,
