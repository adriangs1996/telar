const FramePane = @import("FramePane.zig");
const headless = @import("headless.zig");
const CellType = @import("telar-core").Cell;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const VersionType = @import("../model/Version.zig");
const PaneIdType = @import("telar-core").PaneId;
const GeometryType = @import("Geometry.zig");
const Frame = @This();

cells: [headless.cell_capacity]CellType = undefined,
cell_count: usize = 0,
panes: [max_panes_per_tab_module]FramePane = undefined,
pane_count: usize = 0,
version: VersionType = .{},
focused: ?PaneIdType = null,
geometry: GeometryType = .{},

pub const Pane = @import("FramePane.zig");
