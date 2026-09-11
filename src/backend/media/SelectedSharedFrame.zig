const SelectedSharedFrame = @This();
const SharedFrameKey = @import("SharedFrameKey.zig");
key: SharedFrameKey,
recent_starts: [8]usize = undefined,
recent_count: u4,
start: ?usize = null,
