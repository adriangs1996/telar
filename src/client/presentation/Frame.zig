const Frame = @This();
const source_namespace = @import("headless.zig");
const core = @import("telar-core");
const presentation = @import("root.zig");
cells: [source_namespace.cell_capacity]core.ui.Cell = undefined,
cell_count: usize = 0,
panes: [source_namespace.schema.max_panes_per_tab]Pane = undefined,
pane_count: usize = 0,
version: @import("../model/root.zig").Version = .{},
focused: ?source_namespace.schema.PaneId = null,
geometry: presentation.Geometry = .{},

pub const Pane = struct {
    id: source_namespace.schema.PaneId,
    start: usize,
    len: usize,
    cursor: source_namespace.schema.frame.Cursor,
    mouse: source_namespace.schema.frame.Mouse,
    input_modes: source_namespace.schema.frame.InputModes,
    pointer_shape: source_namespace.schema.frame.PointerShape,
    scroll: source_namespace.schema.frame.Scroll,
};
