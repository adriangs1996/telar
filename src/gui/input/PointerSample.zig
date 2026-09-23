const PointerEvent = @import("PointerEvent.zig");

const Sample = @This();

event: PointerEvent,
geometry_revision: u64,
gesture_revision: u64,
