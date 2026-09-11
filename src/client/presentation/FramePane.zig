const PaneIdType = @import("telar-core").PaneId;
const CursorType = @import("telar-core").Cursor;
const MouseType = @import("telar-core").Mouse;
const InputModesType = @import("telar-core").InputModes;
const PointerShapeType = @import("telar-core").PointerShape;
const ScrollType = @import("telar-core").Scroll;
const Pane = @This();

id: PaneIdType,
start: usize,
len: usize,
cursor: CursorType,
mouse: MouseType,
input_modes: InputModesType,
pointer_shape: PointerShapeType,
scroll: ScrollType,
