const data = @import("../model.zig");
const CopyModeCommit = @This();

active: bool,
viewport: ?data.PaneViewportChange,
copy_revision: u64,
