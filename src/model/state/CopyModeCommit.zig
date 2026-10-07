const data = @import("../model.zig");

active: bool,
viewport: ?data.PaneViewportChange,
copy_revision: u64,
