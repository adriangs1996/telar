const core = @import("telar-core");
const headless = @import("headless.zig");
const VersionType = @import("../model/Version.zig");
const GeometryType = @import("Geometry.zig");
const Frame = @This();

cells: [headless.cell_capacity]core.Cell = undefined,
cell_count: usize = 0,
panes: [core.max_panes_per_tab]Pane = undefined,
pane_count: usize = 0,
version: VersionType = .{},
focused: ?core.PaneId = null,
geometry: GeometryType = .{},

pub const Pane = @import("FramePane.zig");
