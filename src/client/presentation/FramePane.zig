const core = @import("telar-core");
const Pane = @This();

id: core.PaneId,
start: usize,
len: usize,
cursor: core.Cursor,
mouse: core.Mouse,
input_modes: core.InputModes,
pointer_shape: core.PointerShape,
scroll: core.Scroll,
