const Window = @import("telar-window");
const ScrollEvent = @FieldType(Window.Input, "scroll");

event: ScrollEvent,
geometry_revision: u64,
gesture_revision: u64,
started: bool = false,
lines: i8 = 0,
