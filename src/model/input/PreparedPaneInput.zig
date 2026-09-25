const PaneInputSource = @import("PaneInputSource.zig").PaneInputSource;
const limits = @import("limits.zig");
const PreparedPaneInput = @This();

source: PaneInputSource,
bytes: []const u8,
restore_viewport: bool = true,
limit: usize = limits.max_encoded_bytes,
empty_is_noop: bool = false,
