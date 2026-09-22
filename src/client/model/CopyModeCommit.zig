const data = @import("model");
const CopyModeCommit = @This();

active: bool,
viewport: ?data.PaneViewportChange,
copy_revision: u64,
