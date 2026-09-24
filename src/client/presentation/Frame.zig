const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const headless = @import("headless.zig");
const Geometry = @import("Geometry.zig");
const Frame = @This();

cells: [headless.cell_capacity]cellgrid.Cell = undefined,
cell_count: usize = 0,
panes: [core.max_panes_per_tab]Pane = undefined,
pane_count: usize = 0,
version: data.Version = .{},
focused: ?core.PaneId = null,
geometry: Geometry = .{},

pub const Pane = @import("FramePane.zig");
