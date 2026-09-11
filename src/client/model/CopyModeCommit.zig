const PaneViewportChange = @import("PaneViewportChange.zig");
const CopyModeCommit = @This();

active: bool,
viewport: ?PaneViewportChange,
copy_revision: u64,
