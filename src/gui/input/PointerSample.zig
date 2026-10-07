const Window = @import("telar-window");
const PointerEvent = @FieldType(Window.Input, "pointer");

event: PointerEvent,
geometry_revision: u64,
gesture_revision: u64,
