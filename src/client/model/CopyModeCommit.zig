const CopyModeCommit = @This();
const PaneViewportChange = @import("PaneViewportChange.zig");
active: bool,
viewport: ?PaneViewportChange,
copy_revision: u64,
