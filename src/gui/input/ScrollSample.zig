const ScrollEvent = @import("ScrollEvent.zig");

event: ScrollEvent,
geometry_revision: u64,
gesture_revision: u64,
started: bool = false,
lines: i8 = 0,
