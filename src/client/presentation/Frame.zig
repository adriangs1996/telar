const data = @import("model");
const core = @import("telar-core");
const headless = @import("headless.zig");
const GeometryType = @import("Geometry.zig");
const Frame = @This();

cells: [headless.cell_capacity]core.Cell = undefined,
cell_count: usize = 0,
panes: [core.max_panes_per_tab]Pane = undefined,
pane_count: usize = 0,
version: data.Version = .{},
focused: ?core.PaneId = null,
geometry: GeometryType = .{},

pub const Pane = @import("FramePane.zig");
